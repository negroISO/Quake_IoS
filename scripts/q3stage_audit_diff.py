#!/usr/bin/env python3
"""q3stage_audit_diff.py — structural diff of [multi-stage-audit] (Metal)
vs [ioq3-stage-audit] (ioq3 reference) blocks across two qconsole.log
files. Reports: shader-name overlap, stage-count mismatches per shared
shader, and per-stage field deltas. Field encodings differ between the
two engines (Metal's blendMode is a custom enum 0..N; ioq3 dumps raw
GLS_*BLEND nibbles), so we normalize a few well-known mappings before
diffing — see BLEND_NIBBLE_TO_NAME and METAL_BLEND_TO_NAME below.

Usage:
    q3stage_audit_diff.py <metal_qconsole.log> <ioq3_qconsole.log>
    q3stage_audit_diff.py <metal.log> <ioq3.log> --only <shader_glob>
    q3stage_audit_diff.py <metal.log> <ioq3.log> --quiet  # mismatches only

Emits a Markdown report to stdout. Pipe to a file or to less -R."""

from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ioq3 GLS_SRCBLEND_* / GLS_DSTBLEND_* nibble values (tr_local.h).
BLEND_NIBBLE_TO_NAME = {
    0x0: "ZERO",      0x1: "ZERO",      0x2: "ONE",
    0x3: "DST_COLOR", 0x4: "1-DST_COLOR", 0x5: "SRC_ALPHA",
    0x6: "1-SRC_ALPHA", 0x7: "DST_ALPHA", 0x8: "1-DST_ALPHA",
    0x9: "ALPHA_SAT",
}

# Metal's blendMode enum mapping (best-effort — adjust if metal_renderer_shared.h
# enumerates differently). 0=opaque, 3=filter (DST_COLOR,ZERO), 5=additive
# (ONE,ONE) per the Metal-side dump format. This is a SIGNAL for the LLM
# reading the report; treat with the usual "verify in source" caution.
METAL_BLEND_TO_NAME = {
    0: "OPAQUE", 1: "ALPHA_BLEND", 2: "ADDITIVE_DEST",
    3: "FILTER_DST_COLOR", 4: "ALPHA_BLEND_PREMUL",
    5: "ADDITIVE_FULL", 6: "SUBTRACT", 7: "MULTIPLY",
}


@dataclass
class Stage:
    idx: int
    fields: dict[str, str] = field(default_factory=dict)

    def get(self, k: str, default: str = "?") -> str:
        return self.fields.get(k, default)


@dataclass
class ShaderAudit:
    name: str
    stages: int
    cull: int
    stage_lines: list[Stage] = field(default_factory=list)
    source: str = ""  # "metal" | "ioq3"


# Strip Q3 console color codes (^1, ^7, etc.) for clean parsing.
COLOR_RE = re.compile(r"\^[0-9]")
HEADER_RE = re.compile(
    r"\[(?:multi|ioq3)-stage-audit\]\s+'([^']+)'\s+stages=(\d+)\s+cull=(-?\d+)"
)
STAGE_LINE_RE = re.compile(r"^\s*s(\d+):\s+(.*)$")
KV_RE = re.compile(r"(\w+)=('[^']*'|\S+)")


def parse_audit_log(path: Path, source: str) -> dict[str, ShaderAudit]:
    """Walk a qconsole.log and pull every audit block. Returns name → audit
    (last one wins if a shader is audited twice — shouldn't happen due to
    in-engine dedupe, but be defensive)."""
    out: dict[str, ShaderAudit] = {}
    cur: ShaderAudit | None = None
    for raw in path.read_text(errors="replace").splitlines():
        line = COLOR_RE.sub("", raw)
        m = HEADER_RE.search(line)
        if m:
            cur = ShaderAudit(
                name=m.group(1), stages=int(m.group(2)),
                cull=int(m.group(3)), source=source,
            )
            out[cur.name] = cur
            continue
        if cur is None:
            continue
        sm = STAGE_LINE_RE.match(line)
        if not sm:
            # Audit blocks are always header + N adjacent indented stage
            # lines; first non-matching line ends the block.
            cur = None
            continue
        idx = int(sm.group(1))
        fields = {k: v.strip("'") for k, v in KV_RE.findall(sm.group(2))}
        cur.stage_lines.append(Stage(idx=idx, fields=fields))
    return out


def normalize_blend(audit: ShaderAudit, stage: Stage) -> str:
    """Resolve src/dst blend nibbles (ioq3) or blendMode enum (metal) to a
    readable label for diff display. Falls back to raw values if unknown."""
    if audit.source == "ioq3":
        try:
            src = int(stage.get("srcBlend", "0"), 16)
            dst = int(stage.get("dstBlend", "0"), 16)
        except ValueError:
            return f"raw(src={stage.get('srcBlend')},dst={stage.get('dstBlend')})"
        s = BLEND_NIBBLE_TO_NAME.get(src, f"src=0x{src:x}")
        d = BLEND_NIBBLE_TO_NAME.get(dst, f"dst=0x{dst:x}")
        return f"{s},{d}"
    # metal
    try:
        bm = int(stage.get("blend", "0"))
    except ValueError:
        return stage.get("blend", "?")
    return METAL_BLEND_TO_NAME.get(bm, f"raw={bm}")


def _img_basename(path: str) -> str:
    return path.rsplit("/", 1)[-1] if "/" in path else path


def stage_summary(audit: ShaderAudit, stage: Stage) -> str:
    """Single-line per-stage summary in a stable shape so two engines'
    stages can be visually scanned side by side."""
    if audit.source == "ioq3":
        img = _img_basename(stage.get("img", "?"))
        return (
            f"img={img:<24} lm={stage.get('lm','?')} "
            f"blend={normalize_blend(audit, stage):<24} "
            f"rgb={stage.get('rgb','?')} alpha={stage.get('alpha','?')} "
            f"tcGen={stage.get('tcGen','?')} tcMods={stage.get('tcMods','?')} "
            f"depthW={stage.get('depthW','?')}"
        )
    # metal — Metal's per-stage line uses 'map' instead of 'img', no tcGen field
    img = _img_basename(stage.get("map", "?"))
    return (
        f"map={img:<24} lm={stage.get('lm','?')} "
        f"blend={normalize_blend(audit, stage):<24} "
        f"rgb={stage.get('rgb','?')} alpha={stage.get('alpha','?')} "
        f"tcGen=- tcMods={stage.get('tcMods','?')} "
        f"depthW={stage.get('depthW','?')}"
    )


def diff_shader(metal: ShaderAudit, ioq3: ShaderAudit, out: list[str]) -> bool:
    """Return True if any mismatch was reported."""
    mismatched = False
    if metal.stages != ioq3.stages:
        out.append(
            f"  ! STAGE COUNT: metal={metal.stages} ioq3={ioq3.stages}"
        )
        mismatched = True
    if metal.cull != ioq3.cull:
        out.append(f"  ! CULL: metal={metal.cull} ioq3={ioq3.cull}")
        mismatched = True
    n = max(len(metal.stage_lines), len(ioq3.stage_lines))
    for i in range(n):
        m = metal.stage_lines[i] if i < len(metal.stage_lines) else None
        q = ioq3.stage_lines[i] if i < len(ioq3.stage_lines) else None
        if m is None:
            out.append(f"    s{i}  metal: <missing>")
            out.append(f"    s{i}  ioq3:  {stage_summary(ioq3, q)}")
            mismatched = True
            continue
        if q is None:
            out.append(f"    s{i}  metal: {stage_summary(metal, m)}")
            out.append(f"    s{i}  ioq3:  <missing>")
            mismatched = True
            continue
        # both present — print pair, mark mismatch markers
        ms = stage_summary(metal, m)
        qs = stage_summary(ioq3, q)
        diff_marker = " " if ms == qs else "*"
        out.append(f"    s{i}{diff_marker} metal: {ms}")
        out.append(f"    s{i}{diff_marker} ioq3:  {qs}")
    return mismatched


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("metal_log", type=Path)
    p.add_argument("ioq3_log", type=Path)
    p.add_argument("--only", default=None,
                   help="glob-filter shader names (e.g. 'textures/sfx/*')")
    p.add_argument("--quiet", action="store_true",
                   help="hide shaders where every stage matches")
    args = p.parse_args()

    metal = parse_audit_log(args.metal_log, "metal")
    ioq3 = parse_audit_log(args.ioq3_log, "ioq3")
    print(f"# Metal audits: {len(metal)}  ioq3 audits: {len(ioq3)}")
    print(f"# Metal log:    {args.metal_log}")
    print(f"# ioq3  log:    {args.ioq3_log}")
    print()

    common = sorted(set(metal) & set(ioq3))
    only_metal = sorted(set(metal) - set(ioq3))
    only_ioq3 = sorted(set(ioq3) - set(metal))
    if args.only:
        common = [s for s in common if fnmatch.fnmatch(s, args.only)]
        only_metal = [s for s in only_metal if fnmatch.fnmatch(s, args.only)]
        only_ioq3 = [s for s in only_ioq3 if fnmatch.fnmatch(s, args.only)]

    print(f"## Shared shaders ({len(common)})")
    print()
    mismatch_count = 0
    for name in common:
        block: list[str] = []
        block.append(f"### {name}")
        if diff_shader(metal[name], ioq3[name], block):
            mismatch_count += 1
            for line in block:
                print(line)
            print()
        elif not args.quiet:
            for line in block:
                print(line)
            print()
    print(f"# Shared with mismatches: {mismatch_count}/{len(common)}")
    print()

    print(f"## Only in Metal ({len(only_metal)})")
    for n in only_metal:
        print(f"  - {n}  (stages={metal[n].stages})")
    print()
    print(f"## Only in ioq3 ({len(only_ioq3)})")
    for n in only_ioq3:
        print(f"  - {n}  (stages={ioq3[n].stages})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
