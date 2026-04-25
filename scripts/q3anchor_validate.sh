#!/usr/bin/env bash
# q3anchor_validate.sh — capture demo four via the Metal build, then
# produce the fixed-anchor debug pair set that the ralph_loop.txt
# ANCHOR_VALIDATION_ONLY mode operates on.
#
# INPUT (when reading): reference PNG frames under
#   ~/Documents/Quake_IoS/reference/four/frames/frame_NNNN.png
# OUTPUT: ~/Documents/Quake_IoS/debug_pairs/<anchor>/
#   ref.png   — reference frame at the anchor index
#   out.png   — our captured frame at the anchor index
#   info.txt  — anchor type + source paths + frame index
#
# Anchor set (from ralph_loop.txt §9.2):
#   four_frame_119 → ENTITY_LIGHTING
#   four_frame_141 → BLEND_DARKEN
#   four_frame_155 → WORLD_PRECISION
#   four_frame_227 → BLEND_FAILURE_EXTREME
#   four_frame_235 → DECAL_VISIBILITY
#   four_frame_247 → INTERACTION_TIMING
#   four_frame_249 → ADDITIVE_EFFECTS
#
# Usage:
#   scripts/q3anchor_validate.sh [wait_seconds]
# Default 90s. Must be long enough for the demo to reach frame 249
# (~10 s of demo at 25 fps).

set -euo pipefail

REPO=/Users/targus/Documents/Quake_IoS
SIM_UDID="${Q3SIM_UDID:-77575E1E-108A-400D-B844-BCDB8514BE2E}"
BUNDLE_ID="${Q3SIM_BUNDLE:-com.quake3ios.app}"
REF="$REPO/reference/four/frames"
DEBUG_PAIRS="$REPO/debug_pairs"
WAIT_SECONDS=${1:-90}

ANCHOR_INDICES=(119 141 155 227 235 247 249)
anchor_label() {
  case "$1" in
    119) echo ENTITY_LIGHTING ;;
    141) echo BLEND_DARKEN ;;
    155) echo WORLD_PRECISION ;;
    227) echo BLEND_FAILURE_EXTREME ;;
    235) echo DECAL_VISIBILITY ;;
    247) echo INTERACTION_TIMING ;;
    249) echo ADDITIVE_EFFECTS ;;
    *) echo UNKNOWN ;;
  esac
}

stamp=$(date +%Y%m%d_%H%M%S)
SESSION="$HOME/Desktop/q3sim_sessions/${stamp}_anchor"
mkdir -p "$SESSION/frames"
LOG="$SESSION/q3.log"
echo "SESSION=$SESSION"

# Launch the app; ios_main.m autoruns `demo four; video four; wait N;
# stopvideo; quit`. `wait N` must be high enough that frame 249 of
# the demo has been captured — at 25 fps com_maxfps that's ~10 s of
# gameplay after the warmup. The cvar block already sets com_maxfps
# 25 and cg_draw2D 0 (PHASE 1).
xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID" > "$LOG" 2>&1 &
LAUNCH_PID=$!
sleep "$WAIT_SECONDS"
kill "$LAUNCH_PID" 2>/dev/null || true
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

# Copy AVI off the sim and extract frames at the AVI's native rate.
DATA=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)
AVI_SRC="$DATA/Documents/baseq3/videos/four.avi"
if [[ ! -f "$AVI_SRC" ]]; then
  echo "FAIL: no AVI produced at $AVI_SRC"
  exit 2
fi
cp "$AVI_SRC" "$SESSION/four.avi"
ffmpeg -v error -i "$SESSION/four.avi" "$SESSION/frames/frame_%04d.png"

# Resize output frames to reference resolution (960x444) so ref.png
# and out.png are directly comparable pixel-for-pixel.
mkdir -p "$SESSION/frames_960x444"
for f in "$SESSION/frames"/*.png; do
  name=$(basename "$f")
  sips --resampleHeightWidth 444 960 "$f" --out "$SESSION/frames_960x444/$name" >/dev/null 2>&1 || cp "$f" "$SESSION/frames_960x444/$name"
done

# Populate debug_pairs/<anchor>/ for every anchor.
mkdir -p "$DEBUG_PAIRS"
for idx in "${ANCHOR_INDICES[@]}"; do
  label="$(anchor_label "$idx")"
  anchor="four_frame_$(printf '%03d' "$idx")"
  dir="$DEBUG_PAIRS/$anchor"
  mkdir -p "$dir"

  ref_src=$(printf "%s/frame_%04d.png" "$REF" "$idx")
  out_src=$(printf "%s/frames_960x444/frame_%04d.png" "$SESSION" "$idx")

  if [[ -f "$ref_src" ]]; then
    cp "$ref_src" "$dir/ref.png"
  else
    echo "WARN: missing reference for $anchor ($ref_src)"
  fi

  if [[ -f "$out_src" ]]; then
    cp "$out_src" "$dir/out.png"
  else
    echo "WARN: missing output for $anchor ($out_src)"
  fi

  {
    echo "anchor=$anchor"
    echo "type=$label"
    echo "demo=four"
    echo "frame_index=$idx"
    echo "ref_source=$ref_src"
    echo "out_source=$out_src"
    echo "captured_at=$stamp"
  } > "$dir/info.txt"

  echo "[anchor] $anchor ($label) -> $dir"
done

echo ""
echo "=== ANCHOR PAIRS READY ==="
ls -1 "$DEBUG_PAIRS"
echo ""
echo "Run Gemma per anchor using scripts/q3anchor_gemma.sh"
