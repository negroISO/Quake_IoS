#!/usr/bin/env bash
# q3diff_reference.sh — boot the Metal build (which autoruns
# demo four + video capture per ios_main.m), wait for the AVI to
# finalize, copy it off the sim, extract frames at 25fps via ffmpeg,
# diff each frame against the ground-truth reference, and emit a
# PASS/FAIL summary.
#
# Reference dir: /Users/targus/Documents/Quake_IoS/reference/four/frames
# (1497 frames at 960x444, captured at 25fps from ground-truth build).
#
# Output session: ~/Desktop/q3sim_sessions/<stamp>_<label>/
#   four.avi            — copied from the sim
#   frames/             — extracted PNGs, naming matches reference
#   frames_960x444/     — downscaled to exact reference resolution
#   diff/<name>.png     — per-frame ImageChops diff
#   diff.log            — per-frame AE counts
#   summary.txt         — REF_COUNT / OUT_COUNT / TOTAL_AE / AVG_AE
#   q3.log              — engine stdout
#
# Usage:
#   scripts/q3diff_reference.sh <label> [wait_seconds]
# wait_seconds = how long to let the sim run before grabbing the AVI.
# Default 80s (accounts for 3s warmup + 60s recording + 5s close +
# engine boot overhead).

set -euo pipefail

REPO=/Users/targus/Documents/Quake_IoS
SIM_UDID="${Q3SIM_UDID:-77575E1E-108A-400D-B844-BCDB8514BE2E}"
BUNDLE_ID="${Q3SIM_BUNDLE:-com.quake3ios.app}"
REF="$REPO/reference/four/frames"
LABEL=${1:-avi-diff}
WAIT_SECONDS=${2:-80}

stamp=$(date +%Y%m%d_%H%M%S)
SESSION="$HOME/Desktop/q3sim_sessions/${stamp}_${LABEL}"
mkdir -p "$SESSION/frames" "$SESSION/diff"
LOG="$SESSION/q3.log"

echo "SESSION=$SESSION"

# Launch the app; it will autorun demo four + record + quit per the
# temporary Cbuf_AddText block in ios_main.m. We wait wait_seconds,
# then force-close if still running. Output goes to q3.log.
xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID" > "$LOG" 2>&1 &
LAUNCH_PID=$!
sleep "$WAIT_SECONDS"
kill "$LAUNCH_PID" 2>/dev/null || true
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

# Copy the AVI off the sim's data container.
DATA=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)
if [[ ! -f "$DATA/Documents/baseq3/videos/four.avi" ]]; then
  echo "FAIL: no AVI produced at $DATA/Documents/baseq3/videos/four.avi"
  exit 2
fi
cp "$DATA/Documents/baseq3/videos/four.avi" "$SESSION/four.avi"

echo "--- ffprobe ---"
ffprobe -v error -select_streams v -show_streams "$SESSION/four.avi" 2>&1 | head -20 | tee "$SESSION/ffprobe.txt"

# Extract every frame at native rate (AVI is already 25fps, no fps
# filter needed — let ffmpeg's timestamps flow through).
ffmpeg -v error -i "$SESSION/four.avi" "$SESSION/frames/frame_%04d.png"

# Downscale output to exact reference resolution (960x444). The sim
# drawable may settle at 965x442 depending on pixel alignment, which
# pixel-diff would reject.
mkdir -p "$SESSION/frames_960x444"
for f in "$SESSION/frames"/*.png; do
  name=$(basename "$f")
  sips --resampleHeightWidth 444 960 "$f" --out "$SESSION/frames_960x444/$name" >/dev/null 2>&1 || cp "$f" "$SESSION/frames_960x444/$name"
done

REF_COUNT=$(ls "$REF"/*.png 2>/dev/null | wc -l | tr -d ' ')
OUT_COUNT=$(ls "$SESSION/frames_960x444"/*.png 2>/dev/null | wc -l | tr -d ' ')

SUMMARY="$SESSION/summary.txt"
{
  echo "REF_COUNT=$REF_COUNT"
  echo "OUT_COUNT=$OUT_COUNT"
  echo "REF_DIR=$REF"
  echo "OUT_DIR=$SESSION/frames_960x444"
} > "$SUMMARY"

# STEP 1 pipeline:
# 1. Find first non-black frame (mean pixel < 5) on BOTH streams.
#    Both capture + reference have leading black frames from
#    map-load; aligning AFTER the first real frame removes that
#    artifact from the offset math.
# 2. Content-based alignment via RGB histogram correlation on the
#    first-non-black pair, searching ±20 frames for the best match.
#    Timing-based heuristics are REMOVED.
# 3. Apply the detected offset, diff every matched pair.
python3 - "$SESSION/frames_960x444" "$REF" "$SUMMARY" "$SESSION/diff" "$SESSION/diff.log" <<'PY'
import os, sys, glob
import numpy as np
from PIL import Image, ImageChops
out_dir, ref_dir, summary_path, diff_dir, diff_log_path = sys.argv[1:6]

out_frames = sorted(glob.glob(os.path.join(out_dir, "*.png")))
ref_frames = sorted(glob.glob(os.path.join(ref_dir, "*.png")))

def idx_of(path):
    name = os.path.basename(path).removesuffix(".png").replace("frame_", "")
    try: return int(name)
    except ValueError: return -1

def is_black(path):
    """True when mean luminance < 5 (per the spec)."""
    img = np.asarray(Image.open(path).convert("L"), dtype=np.float32)
    return float(img.mean()) < 5.0

def hist_similarity(path_a, path_b):
    """RGB histogram correlation — higher is more similar.
    Downsample to 160x74 for speed; 32 bins per channel."""
    a = np.asarray(Image.open(path_a).convert("RGB").resize((160, 74)))
    b = np.asarray(Image.open(path_b).convert("RGB").resize((160, 74)))
    score = 0.0
    for c in range(3):
        ha, _ = np.histogram(a[..., c], bins=32, range=(0, 256), density=True)
        hb, _ = np.histogram(b[..., c], bins=32, range=(0, 256), density=True)
        # Normalized cross-correlation on normalised histograms.
        na = ha - ha.mean(); nb = hb - hb.mean()
        den = float(np.sqrt((na * na).sum() * (nb * nb).sum())) + 1e-9
        score += float((na * nb).sum()) / den
    return score

def first_non_black(paths):
    for p in paths:
        if not is_black(p):
            return p
    return None

out_first = first_non_black(out_frames)
ref_first = first_non_black(ref_frames)
if out_first is None or ref_first is None:
    raise SystemExit("FAIL: all frames black on one side")

out_first_idx = idx_of(out_first)
ref_first_idx = idx_of(ref_first)

# Content-based alignment: ref[out_first_idx + offset] should best
# match out[out_first_idx]. offset = ref_first_idx - out_first_idx
# is the starting point; search ±20 around that.
base_offset = ref_first_idx - out_first_idx
best_score = -1e9
best_offset = base_offset
for d in range(-20, 21):
    cand = base_offset + d
    ref_idx = out_first_idx + cand
    ref_path = os.path.join(ref_dir, f"frame_{ref_idx:04d}.png")
    if not os.path.isfile(ref_path):
        continue
    score = hist_similarity(out_first, ref_path)
    if score > best_score:
        best_score = score
        best_offset = cand

print(f"out_first={out_first_idx} ref_first={ref_first_idx} "
      f"base_offset={base_offset} best_offset={best_offset} "
      f"best_score={best_score:.4f}", flush=True)

# Diff every frame using the detected offset.
ref_by_idx = {idx_of(p): p for p in ref_frames}
total_ae = 0
per_frame = []
lines = []
matched = 0
skipped_black = 0
for out_path in out_frames:
    if is_black(out_path):
        skipped_black += 1
        continue
    oi = idx_of(out_path)
    ri = oi + best_offset
    if ri not in ref_by_idx:
        continue
    out_img = Image.open(out_path).convert("RGB")
    ref_img = Image.open(ref_by_idx[ri]).convert("RGB")
    if out_img.size != ref_img.size:
        out_img = out_img.resize(ref_img.size)
    diff = ImageChops.difference(out_img, ref_img)
    diff.save(os.path.join(diff_dir, os.path.basename(out_path)))
    frame_ae = int(np.count_nonzero(np.asarray(diff).any(axis=-1)))
    total_ae += frame_ae
    per_frame.append(frame_ae)
    lines.append(f"{os.path.basename(out_path)} <-> frame_{ri:04d}.png: AE={frame_ae}")
    matched += 1

with open(diff_log_path, "w") as f:
    f.write("\n".join(lines) + "\n")

with open(summary_path, "a") as f:
    f.write(f"DETECTED_OFFSET={best_offset}\n")
    f.write(f"ALIGN_SCORE={best_score:.4f}\n")
    f.write(f"SKIPPED_BLACK={skipped_black}\n")
    f.write(f"MATCHED_FRAMES={matched}\n")
    f.write(f"TOTAL_AE={total_ae}\n")
    if per_frame:
        avg = total_ae / len(per_frame)
        f.write(f"AVG_AE_PER_FRAME={avg:.1f}\n")

print(f"OFFSET={best_offset} MATCHED={matched} TOTAL_AE={total_ae}")
PY

echo ""
echo "=== SUMMARY ==="
cat "$SUMMARY"
echo ""

TOTAL_AE=$(awk -F= '/^TOTAL_AE=/{print $2}' "$SUMMARY")
if [[ -z "${TOTAL_AE:-}" ]]; then
  echo "FAIL: diff phase produced no TOTAL_AE"
  exit 3
fi

echo "Diff images: $SESSION/diff/"
echo "Diff log:    $SESSION/diff.log"
echo "Summary:     $SUMMARY"
echo "AVI:         $SESSION/four.avi"

if [[ "$REF_COUNT" -ne "$OUT_COUNT" ]]; then
  echo "WARN: frame count mismatch (REF=$REF_COUNT OUT=$OUT_COUNT)"
fi
if [[ "$TOTAL_AE" -gt 0 ]]; then
  echo "FAIL: $TOTAL_AE total pixels differ from reference"
  exit 1
else
  echo "PASS: all pixels match reference"
fi
