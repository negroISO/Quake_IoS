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

# Frame alignment: demo playback is deterministic per engine time, but
# the reference capture and ours may start from slightly different
# demo moments (warmup offset, boot load time, etc). Auto-detect the
# offset K such that ours[i] best matches ref[i + K] by sampling a
# handful of anchor frames and searching a ±60 frame window.
python3 - "$SESSION/frames_960x444" "$REF" "$SUMMARY" "$SESSION/diff" "$SESSION/diff.log" <<'PY'
import os, sys, glob, statistics
from PIL import Image, ImageChops
out_dir, ref_dir, summary_path, diff_dir, diff_log_path = sys.argv[1:6]

out_frames = sorted(glob.glob(os.path.join(out_dir, "*.png")))
ref_frames = sorted(glob.glob(os.path.join(ref_dir, "*.png")))

def idx_of(path):
    """Extract the 4-digit frame index from frame_NNNN.png."""
    name = os.path.basename(path).removesuffix(".png").replace("frame_", "")
    try:
        return int(name)
    except ValueError:
        return -1

def ae(a_path, b_path):
    a = Image.open(a_path).convert("RGB").resize((320, 148))  # downsample for speed
    b = Image.open(b_path).convert("RGB").resize((320, 148))
    d = ImageChops.difference(a, b)
    # Sum of absolute byte differences — cheaper than counting
    # nonzero pixels and gives a smoother landscape for argmin.
    return sum(d.tobytes())

ref_by_idx = {idx_of(p): p for p in ref_frames}
out_by_idx = {idx_of(p): p for p in out_frames}

# Pick three anchor frames from the middle-ish of our capture to
# avoid boot-time transients. For each, search reference window
# [anchor - 60, anchor + 60] for minimum-AE match; the offset
# difference is our candidate K. Average across anchors.
out_indices = sorted(out_by_idx.keys())
n_out = len(out_indices)
if n_out < 30:
    offset = 0
else:
    anchors = [out_indices[n_out // 4], out_indices[n_out // 2], out_indices[3 * n_out // 4]]
    offsets = []
    ref_max = max(ref_by_idx.keys())
    for anchor_out in anchors:
        best = None
        # Widen search to ±400 frames — the `wait N` warmup before
        # recording starts can easily shift us 75-200 frames relative
        # to reference, and simulator-speed skew adds more drift over
        # the capture window.
        for delta in range(-400, 401):
            cand = anchor_out + delta
            if cand < 1 or cand > ref_max:
                continue
            if cand not in ref_by_idx:
                continue
            score = ae(out_by_idx[anchor_out], ref_by_idx[cand])
            if best is None or score < best[0]:
                best = (score, delta)
        if best is not None:
            offsets.append(best[1])
    # Anchors may land at different offsets if the demos drift (ours
    # running slightly faster/slower than ref); fall back to the
    # median, report all three for inspection.
    offset = int(round(statistics.median(offsets))) if offsets else 0
    print(f"anchor_offsets={offsets} median={offset}", flush=True)

# Apply offset: ours[i] pairs with ref[i + offset].
total_ae = 0
per_frame = []
lines = []
matched = 0
for out_path in out_frames:
    oi = idx_of(out_path)
    ri = oi + offset
    if ri not in ref_by_idx:
        continue
    out_img = Image.open(out_path).convert("RGB")
    ref_img = Image.open(ref_by_idx[ri]).convert("RGB")
    if out_img.size != ref_img.size:
        out_img = out_img.resize(ref_img.size)
    diff = ImageChops.difference(out_img, ref_img)
    diff.save(os.path.join(diff_dir, os.path.basename(out_path)))
    frame_ae = sum(1 for p in diff.getdata() if p != (0, 0, 0))
    total_ae += frame_ae
    per_frame.append(frame_ae)
    lines.append(f"{os.path.basename(out_path)} <-> frame_{ri:04d}.png: AE={frame_ae}")
    matched += 1

with open(diff_log_path, "w") as f:
    f.write("\n".join(lines) + "\n")

with open(summary_path, "a") as f:
    f.write(f"DETECTED_OFFSET={offset}\n")
    f.write(f"MATCHED_FRAMES={matched}\n")
    f.write(f"TOTAL_AE={total_ae}\n")
    if per_frame:
        avg = total_ae / len(per_frame)
        f.write(f"AVG_AE_PER_FRAME={avg:.1f}\n")

print(f"OFFSET={offset} MATCHED={matched} TOTAL_AE={total_ae}")
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
