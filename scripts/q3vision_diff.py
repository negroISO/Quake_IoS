#!/usr/bin/env python3
"""
q3vision_diff.py — sample paired frames from our AVI and the reference,
ask a multimodal LLM what's missing/wrong on each pair, and aggregate
the verdicts into a single markdown report.

Builds on top of:
  - reference/four/frames/        (1497 ground-truth frames @ 25fps, 960x444)
  - the AVI captured by q3sim_run.sh into a session folder
  - the strict auditor prompt established in scripts/q3anchor_gemma.sh

Two model backends:
  - lmstudio (default): the LM Studio endpoint already wired up in
    q3anchor_gemma.sh (google/gemma-4-31b at http://192.168.0.77:1234).
    Free, local, multimodal Gemma 3.
  - claude: Anthropic Claude Sonnet 4.6 via the anthropic SDK. Higher
    fidelity vision analysis at ~$0.003/pair. Requires ANTHROPIC_API_KEY
    and `pip install anthropic`.

Usage:
  scripts/q3vision_diff.py                          # auto-pick latest session
  scripts/q3vision_diff.py --session <folder>       # explicit session folder
  scripts/q3vision_diff.py --backend claude         # use Claude API
  scripts/q3vision_diff.py --n 60                   # sample 60 frames (default 30)

Output: <session>/vision_report.md
"""

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_REF = REPO / "reference" / "four" / "frames"
DEFAULT_SESSIONS = Path.home() / "Desktop" / "q3sim_sessions"

PROMPT_SYSTEM = """You are a strict Quake 3 rendering-parity auditor. You receive two images: the first (OURS) is our custom Metal renderer output; the second (REF) is the ground-truth reference render of the same demo frame. Compare ONLY these two images. Ignore compression artifacts, minor brightness variance, and resolution differences. Focus on STRUCTURAL rendering differences — what is missing, what is added, what is wrong.

Output MUST match this exact format and nothing else:
MATCH: PASS | FAIL
DIFF_TYPE: BLEND | LIGHTING | ENTITY | WORLD | SKY | PARTICLE | DECAL | FOG | UI | PRECISION | UNKNOWN
MISSING: <comma-separated list of features visible in REF but absent in OURS, or "none">
EXTRA: <comma-separated list of features visible in OURS but not in REF, or "none">
OBSERVATIONS:
- <bullet>
- <bullet>
ROOT_CAUSE: <single Q3 concept: blendFunc | rgbGen | lightingDiffuse | alphaFunc | tcMod | tcGen | lightmap | fogParms | shader | unknown>
CONFIDENCE: HIGH | MEDIUM | LOW

Decision logic:
- decals (bullet marks, blood, scorch) absent or shaped wrong → DECAL
- scene-wide tint, glow, or bleed → BLEND
- player/entity lighting diverges from reference → ENTITY or LIGHTING
- floor/wall banding or color shift → PRECISION
- explosions / particles missing or oversaturated → PARTICLE / BLEND
- sky banding, missing clouds, wrong cubemap → SKY
- fog absent or color wrong → FOG
- HUD/menu element missing → UI
- geometry correct but shading off → LIGHTING

HARD RULES: NO guessing. NO multiple root causes. NO "maybe". ONLY upstream Quake 3 behavior allowed."""


def latest_session_with_avi() -> Path | None:
    if not DEFAULT_SESSIONS.exists():
        return None
    candidates = sorted(
        [p for p in DEFAULT_SESSIONS.iterdir() if p.is_dir() and (p / "four.avi").exists()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def extract_our_frames(avi: Path, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    if any(out_dir.glob("frame_*.png")):
        return sorted(out_dir.glob("frame_*.png"))
    subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(avi),
         "-vf", "scale=960:444",
         str(out_dir / "frame_%04d.png")],
        check=True,
    )
    return sorted(out_dir.glob("frame_*.png"))


def png_b64(path: Path) -> str:
    """Encode a PNG to base64. Large source PNGs (e.g. 1920x1080 anchor
    captures) overflow LM Studio's vision encoder with HTTP 500. Cap the
    longest side at 960 px via macOS `sips` before encoding. The AVI
    extraction path already produces 960x444; this only triggers on
    anchor mode."""
    src = path
    try:
        sz = src.stat().st_size
        if sz > 200_000:  # ~200 KB threshold catches native-res anchors
            tmp = Path("/tmp") / f"q3vd_{path.stem}_{path.parent.name}.png"
            subprocess.run(
                ["sips", "-Z", "960", str(src), "--out", str(tmp)],
                check=True, capture_output=True,
            )
            src = tmp
    except Exception:
        pass  # fall through with original
    return base64.standard_b64encode(src.read_bytes()).decode()


def call_lmstudio(our_png: Path, ref_png: Path, url: str, model: str) -> str:
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": PROMPT_SYSTEM},
            {"role": "user", "content": [
                {"type": "text", "text": "OURS (Metal renderer output):"},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/png;base64,{png_b64(our_png)}"}},
                {"type": "text", "text": "REF (ground truth):"},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/png;base64,{png_b64(ref_png)}"}},
            ]},
        ],
        "temperature": 0,
        "max_tokens": 512,
    }
    req = urllib.request.Request(
        f"{url}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        out = json.loads(r.read())
    return out["choices"][0]["message"]["content"]


def call_claude(our_png: Path, ref_png: Path, model: str) -> str:
    import anthropic  # lazy: only when backend=claude
    client = anthropic.Anthropic()
    msg = client.messages.create(
        model=model,
        max_tokens=512,
        system=PROMPT_SYSTEM,
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": "OURS (Metal renderer output):"},
                {"type": "image", "source": {
                    "type": "base64", "media_type": "image/png",
                    "data": png_b64(our_png)}},
                {"type": "text", "text": "REF (ground truth):"},
                {"type": "image", "source": {
                    "type": "base64", "media_type": "image/png",
                    "data": png_b64(ref_png)}},
            ],
        }],
    )
    return msg.content[0].text


def parse_verdict(text: str) -> dict:
    """Parse the strict-format response. Tolerant to minor whitespace
    variance; rejects anything where MATCH or DIFF_TYPE is missing."""
    out = {"raw": text}
    pat = {
        "match": r"MATCH:\s*(PASS|FAIL)",
        "diff_type": r"DIFF_TYPE:\s*([A-Z_]+)",
        "missing": r"MISSING:\s*(.+)",
        "extra": r"EXTRA:\s*(.+)",
        "root_cause": r"ROOT_CAUSE:\s*([a-zA-Z_| ]+)",
        "confidence": r"CONFIDENCE:\s*(HIGH|MEDIUM|LOW)",
    }
    for k, p in pat.items():
        m = re.search(p, text)
        out[k] = m.group(1).strip() if m else None
    obs_match = re.search(r"OBSERVATIONS:\s*\n((?:- .+\n?)+)", text)
    out["observations"] = (
        [line[2:].strip() for line in obs_match.group(1).strip().split("\n")]
        if obs_match else []
    )
    return out


def synthesize(verdicts: list[dict]) -> str:
    n = len(verdicts)
    valid = [v for v in verdicts if v.get("match") in ("PASS", "FAIL")]
    pass_n = sum(1 for v in valid if v["match"] == "PASS")
    fail_n = sum(1 for v in valid if v["match"] == "FAIL")
    parse_failures = n - len(valid)

    diff_hist = Counter(v.get("diff_type") for v in valid)
    cause_hist = Counter(v.get("root_cause") for v in valid)
    conf_hist = Counter(v.get("confidence") for v in valid)

    missing_items: Counter = Counter()
    extra_items: Counter = Counter()
    for v in valid:
        for src, sink in [("missing", missing_items), ("extra", extra_items)]:
            raw = v.get(src) or "none"
            if raw.lower() == "none":
                continue
            for item in [s.strip() for s in raw.split(",") if s.strip()]:
                sink[item] += 1

    obs_hist: Counter = Counter()
    for v in valid:
        for o in v.get("observations", []):
            obs_hist[o] += 1

    lines = []
    lines.append("# q3vision_diff report\n")
    lines.append(f"- pairs sampled: **{n}**")
    lines.append(f"- parsed verdicts: **{len(valid)}** ({parse_failures} parse failures)")
    if valid:
        lines.append(f"- PASS / FAIL: **{pass_n} / {fail_n}** "
                     f"({pass_n / len(valid) * 100:.0f}% pass)")
    lines.append("")

    if diff_hist:
        lines.append("## DIFF_TYPE histogram")
        for k, c in diff_hist.most_common():
            lines.append(f"- {k}: **{c}**")
        lines.append("")
    if cause_hist:
        lines.append("## ROOT_CAUSE histogram")
        for k, c in cause_hist.most_common():
            lines.append(f"- `{k}`: **{c}**")
        lines.append("")
    if missing_items:
        lines.append("## Most-cited MISSING features (REF has, OURS doesn't)")
        for k, c in missing_items.most_common(15):
            lines.append(f"- {k} ({c}×)")
        lines.append("")
    if extra_items:
        lines.append("## Most-cited EXTRA features (OURS has, REF doesn't)")
        for k, c in extra_items.most_common(15):
            lines.append(f"- {k} ({c}×)")
        lines.append("")
    if obs_hist:
        lines.append("## Most-recurring observations")
        for k, c in obs_hist.most_common(15):
            lines.append(f"- {k} ({c}×)")
        lines.append("")

    lines.append("## Per-frame verdicts")
    lines.append("| frame | MATCH | DIFF_TYPE | ROOT_CAUSE | CONF |")
    lines.append("|---|---|---|---|---|")
    for v in verdicts:
        lines.append(f"| {v.get('frame_idx', '?')} | "
                     f"{v.get('match', '—')} | {v.get('diff_type', '—')} | "
                     f"{v.get('root_cause', '—')} | {v.get('confidence', '—')} |")
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", type=Path, default=None,
                    help="session folder containing four.avi (default: latest)")
    ap.add_argument("--ref-frames", type=Path, default=DEFAULT_REF)
    ap.add_argument("--n", type=int, default=30, help="number of frame pairs")
    ap.add_argument("--skip-warmup", type=int, default=80,
                    help="drop the first N frames on both sides before sampling. "
                         "Cleans up demo intro/loading frames where alignment is unreliable.")
    ap.add_argument("--anchors", type=Path, default=None,
                    help="instead of sampling our AVI, use a debug_pairs/ "
                         "directory with per-frame subfolders containing "
                         "out.png + ref.png (pre-aligned).")
    ap.add_argument("--backend", choices=["lmstudio", "claude"], default="lmstudio")
    ap.add_argument("--lmstudio-url", default=os.environ.get(
        "LMSTUDIO_URL", "http://192.168.0.77:1234"))
    ap.add_argument("--lmstudio-model", default=os.environ.get(
        "LMSTUDIO_MODEL", "google/gemma-4-31b"))
    ap.add_argument("--claude-model", default="claude-sonnet-4-6")
    args = ap.parse_args()

    # Pre-aligned anchor mode: skip AVI extraction, just iterate
    # debug_pairs/four_frame_*/(out.png, ref.png).
    if args.anchors:
        pairs = []
        for sub in sorted(args.anchors.iterdir()):
            if not sub.is_dir():
                continue
            o = sub / "out.png"
            r = sub / "ref.png"
            if o.exists() and r.exists():
                pairs.append((sub.name, o, r))
        if not pairs:
            sys.exit(f"ERR: no out.png/ref.png pairs in {args.anchors}")
        print(f"anchors:    {len(pairs)} pre-aligned pairs from {args.anchors}")
        print(f"backend:    {args.backend}")
        out_dir = args.anchors
        verdicts = []
        for n_done, (name, our, ref) in enumerate(pairs, 1):
            print(f"  [{n_done}/{len(pairs)}] {name}", flush=True)
            try:
                if args.backend == "claude":
                    resp = call_claude(our, ref, args.claude_model)
                else:
                    resp = call_lmstudio(our, ref,
                                         args.lmstudio_url, args.lmstudio_model)
            except Exception as e:
                print(f"    ERR: {e}", file=sys.stderr)
                verdicts.append({"frame_idx": name, "raw": f"ERROR: {e}"})
                continue
            v = parse_verdict(resp)
            v["frame_idx"] = name
            verdicts.append(v)
            print(f"    {v.get('match', '?')} / {v.get('diff_type', '?')} / "
                  f"{v.get('root_cause', '?')}")
        report = synthesize(verdicts)
        out_md = out_dir / "vision_report.md"
        out_md.write_text(report)
        (out_dir / "vision_raw.json").write_text(json.dumps(verdicts, indent=2))
        print(f"\n→ report: {out_md}")
        return

    session = args.session or latest_session_with_avi()
    if not session:
        sys.exit("ERR: no session folder with four.avi found")
    avi = session / "four.avi"
    if not avi.exists():
        sys.exit(f"ERR: {avi} not found")

    ref_frames = sorted(args.ref_frames.glob("frame_*.png"))
    if not ref_frames:
        sys.exit(f"ERR: no reference frames at {args.ref_frames}")

    print(f"session:    {session}")
    print(f"avi:        {avi}")
    print(f"ref frames: {len(ref_frames)} at {args.ref_frames}")
    print(f"backend:    {args.backend}")
    print(f"n samples:  {args.n} (skip-warmup={args.skip_warmup})")

    our_frames_dir = session / "frames"
    our_frames = extract_our_frames(avi, our_frames_dir)
    if not our_frames:
        sys.exit("ERR: ffmpeg extracted no frames")
    print(f"our frames: {len(our_frames)} extracted")

    # Drop warmup frames on both sides so the demo-startup splash /
    # cgame-init mismatch doesn't dominate the verdict. Index alignment
    # is still naive (frame i ↔ frame i after warmup) — content-based
    # alignment via match_frames.py is a separate next step.
    skip = max(0, args.skip_warmup)
    our_pool = our_frames[skip:]
    ref_pool = ref_frames[skip:]
    pool_len = min(len(our_pool), len(ref_pool))
    if pool_len <= 0:
        sys.exit(f"ERR: skip-warmup={skip} drops everything")

    n_pairs = min(args.n, pool_len)
    indices = [int(i * (pool_len - 1) / max(n_pairs - 1, 1))
               for i in range(n_pairs)]
    indices = sorted(set(indices))[:n_pairs]

    verdicts = []
    for n_done, idx in enumerate(indices, 1):
        our = our_pool[idx]
        ref = ref_pool[idx]
        print(f"  [{n_done}/{len(indices)}] frame {idx}: "
              f"{our.name} vs {ref.name}", flush=True)
        try:
            if args.backend == "claude":
                resp = call_claude(our, ref, args.claude_model)
            else:
                resp = call_lmstudio(our, ref,
                                     args.lmstudio_url, args.lmstudio_model)
        except Exception as e:
            print(f"    ERR: {e}", file=sys.stderr)
            verdicts.append({"frame_idx": idx, "raw": f"ERROR: {e}"})
            continue
        v = parse_verdict(resp)
        v["frame_idx"] = idx
        verdicts.append(v)
        print(f"    {v.get('match', '?')} / {v.get('diff_type', '?')} / "
              f"{v.get('root_cause', '?')}")

    report = synthesize(verdicts)
    out_md = session / "vision_report.md"
    out_md.write_text(report)
    print(f"\n→ report: {out_md}")
    raw_log = session / "vision_raw.json"
    raw_log.write_text(json.dumps(verdicts, indent=2))
    print(f"→ raw:    {raw_log}")


if __name__ == "__main__":
    main()
