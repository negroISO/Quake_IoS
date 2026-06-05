#!/usr/bin/env python3
"""Build a temporary Q3 shader-name -> RTX DDS material table by filename heuristics.

This is a fallback when exact RTX Remix shader->hash mapping is missing.
It matches each BSP shader name against DDS filenames by normalized basename
substring/tokens, then writes a renderer-compatible materials.json.

Usage:
  scripts/heuristic_rtx_materials.py <shader_list.txt> <rtx_assets_root> <output_pbr_dir> [--copy]

Examples:
  scripts/bsp_shader_names.py baseq3/pak0.pk3 maps/q3dm17.bsp /tmp/q3dm17_shaders.txt
  scripts/heuristic_rtx_materials.py /tmp/q3dm17_shaders.txt /path/to/q3rtx_v07/assets /tmp/q3dm17_pbr --copy

Output:
  <output_pbr_dir>/materials.json
  <output_pbr_dir>/heuristic_matches.tsv
  <output_pbr_dir>/assets/ingested/*.dds   (only with --copy)
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

TEXTURE_KEYS = ("albedo", "normal", "roughness", "metallic", "emissive", "height")
DDS_EXTS = {".dds", ".rtex.dds"}

# Ordered strongest -> weakest. RTX Remix exports vary: .a.rtex.dds,
# _albedo.dds, _normal_used_detailed_OTH_Normal.n.rtex.dds, etc.
KEY_PATTERNS: list[tuple[str, tuple[str, ...]]] = [
    ("normal", ("normal", "_n.", ".n.", "_n_", "bump")),
    ("roughness", ("roughness", "_r.", ".r.", "_r_", "rough")),
    ("metallic", ("metallic", "metalness", "_m.", ".m.", "_m_", "metal")),
    ("emissive", ("emissive", "emission", "_e.", ".e.", "_e_", "emit")),
    ("height", ("height", "displace", "disp", "_h.", ".h.", "_h_")),
    ("albedo", ("albedo", "diffuse", "basecolor", "base_color", "_a.", ".a.", "_d.", ".d.")),
]

STOP_WORDS = {
    "textures", "models", "mapobjects", "base", "wall", "floor", "ceiling",
    "gothic", "gothic_block", "sfx", "common", "effects", "shader", "used",
    "detailed", "oth", "rtx", "remix", "rtex", "dds", "tga", "jpg", "jpeg",
    "png", "normal", "roughness", "metallic", "metalness", "albedo",
    "diffuse", "basecolor", "emissive", "height",
}


def strip_ext(name: str) -> str:
    low = name.lower()
    for ext in (".rtex.dds", ".dds", ".tga", ".jpg", ".jpeg", ".png"):
        if low.endswith(ext):
            return name[: -len(ext)]
    return name


def norm(s: str) -> str:
    s = strip_ext(s.replace("\\", "/").strip().lower())
    s = re.sub(r"[^a-z0-9]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def tokens(s: str) -> list[str]:
    out: list[str] = []
    for t in norm(s).split("_"):
        if len(t) >= 3 and t not in STOP_WORDS:
            out.append(t)
    return out


def shader_stems(shader: str) -> list[str]:
    parts = shader.replace("\\", "/").split("/")
    stems = [norm(parts[-1])]
    if len(parts) >= 2:
        stems.append(norm("_".join(parts[-2:])))
    stems.append(norm(shader))
    # Q3 often has suffix variants: foo_d, foo_df, foo_blend.
    extra: list[str] = []
    for st in stems:
        for suffix in ("_df", "_d", "_blend", "_glow", "_glo"):
            if st.endswith(suffix):
                extra.append(st[: -len(suffix)])
    seen = []
    for st in stems + extra:
        if st and st not in seen:
            seen.append(st)
    return seen


def classify_texture(path: Path) -> str:
    n = norm(path.name)
    padded = f"_{n}_"
    for key, pats in KEY_PATTERNS:
        for pat in pats:
            if pat.startswith("_") or pat.startswith("."):
                if pat.replace(".", "_") in padded:
                    return key
            elif pat in n:
                return key
    return "albedo"


@dataclass(frozen=True)
class Candidate:
    path: Path
    rel: str
    kind: str
    norm_name: str
    toks: tuple[str, ...]


def discover_dds(root: Path) -> list[Candidate]:
    candidates: list[Candidate] = []
    search_roots = [root]
    if (root / "ingested").is_dir():
        search_roots.insert(0, root / "ingested")
    if (root / "assets" / "ingested").is_dir():
        search_roots.insert(0, root / "assets" / "ingested")
    seen: set[Path] = set()
    for sr in search_roots:
        for p in sr.rglob("*.dds"):
            if p in seen:
                continue
            seen.add(p)
            try:
                rel = p.relative_to(root).as_posix()
            except ValueError:
                rel = p.name
            candidates.append(Candidate(p, rel, classify_texture(p), norm(p.stem), tuple(tokens(p.stem))))
    return candidates


def score(shader: str, cand: Candidate) -> int:
    stems = shader_stems(shader)
    c = cand.norm_name
    best = 0
    for st in stems:
        if not st:
            continue
        if c == st:
            best = max(best, 1000 + len(st))
        elif st in c:
            best = max(best, 800 + len(st))
        elif c in st and len(c) >= 5:
            best = max(best, 650 + len(c))
    sh_toks = set(tokens(shader))
    if sh_toks and cand.toks:
        overlap = sh_toks.intersection(cand.toks)
        if overlap:
            best = max(best, 100 * len(overlap) + sum(len(x) for x in overlap))
    return best


def choose_matches(shader: str, candidates: list[Candidate], min_score: int) -> tuple[dict[str, Candidate], int]:
    per_kind: dict[str, tuple[int, Candidate]] = {}
    top_score = 0
    for cand in candidates:
        sc = score(shader, cand)
        if sc < min_score:
            continue
        top_score = max(top_score, sc)
        cur = per_kind.get(cand.kind)
        if cur is None or sc > cur[0] or (sc == cur[0] and len(cand.path.name) < len(cur[1].path.name)):
            per_kind[cand.kind] = (sc, cand)
    return {k: v for k, (_, v) in per_kind.items()}, top_score


def material_id(shader: str) -> str:
    return "heur_" + norm(shader)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("shader_list", type=Path)
    ap.add_argument("rtx_assets_root", type=Path)
    ap.add_argument("output_pbr_dir", type=Path)
    ap.add_argument("--copy", action="store_true", help="copy matched DDS files to output/assets/ingested and rewrite paths")
    ap.add_argument("--min-score", type=int, default=120, help="minimum match score; lower finds more false positives")
    args = ap.parse_args()

    shaders = [ln.strip() for ln in args.shader_list.read_text().splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    candidates = discover_dds(args.rtx_assets_root)
    out_dir = args.output_pbr_dir
    ingested = out_dir / "assets" / "ingested"
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.copy:
        ingested.mkdir(parents=True, exist_ok=True)

    materials: dict[str, dict] = {}
    by_name: dict[str, dict] = {}
    rows = ["shader\tscore\tkind\tsource"]
    matched = 0
    copied_files: set[Path] = set()

    for shader in shaders:
        found, top = choose_matches(shader, candidates, args.min_score)
        if not found:
            rows.append(f"{shader}\t0\t-\t-")
            continue
        matched += 1
        mid = material_id(shader)
        mat = {"hash": mid, "shaderName": shader, "heuristic": True, "matchScore": top}
        for key in TEXTURE_KEYS:
            cand = found.get(key)
            if not cand:
                continue
            rel = cand.rel
            if args.copy:
                dst = ingested / cand.path.name
                if cand.path not in copied_files:
                    shutil.copy2(cand.path, dst)
                    copied_files.add(cand.path)
                rel = f"assets/ingested/{dst.name}"
            mat[key] = rel
            rows.append(f"{shader}\t{score(shader, cand)}\t{key}\t{cand.rel}")
        materials[mid] = mat
        by_name[shader] = mat

    out = {
        "metadata": {
            "mode": "heuristic_filename_substring",
            "shader_list": str(args.shader_list),
            "rtx_assets_root": str(args.rtx_assets_root),
            "shader_count": len(shaders),
            "matched_shader_count": matched,
            "candidate_dds_count": len(candidates),
            "min_score": args.min_score,
            "copied_file_count": len(copied_files),
        },
        "materials": materials,
        "materials_by_name": by_name,
    }
    (out_dir / "materials.json").write_text(json.dumps(out, indent=2))
    (out_dir / "heuristic_matches.tsv").write_text("\n".join(rows) + "\n")
    print(f"shaders: {len(shaders)}")
    print(f"dds candidates: {len(candidates)}")
    print(f"matched shaders: {matched}")
    print(f"materials: {len(materials)}")
    print(f"copied files: {len(copied_files)}")
    print(f"output: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
