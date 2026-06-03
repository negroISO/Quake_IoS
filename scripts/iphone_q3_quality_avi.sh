#!/usr/bin/env bash
# iphone_q3_quality_avi.sh — capture one Q3 demo at one MetalFX quality
# level, save the resulting AVI (and a compressed .mp4 if ffmpeg is on
# PATH) to a host-side output directory.
#
# How it works
#   1. devicectl launches Q3 with two env vars:
#        Q3_UPSCALE_QUALITY=<quality>   (Native / High / Medium / Low)
#        Q3_LAUNCH_COMMAND=<Cbuf chain> (demo + video + stopvideo)
#   2. The Cbuf chain plays the demo, waits a moment, starts AVI
#      recording, waits for the capture window, stops recording.
#   3. We wait the wall-clock equivalent, then terminate the app so the
#      AVI handle is closed.
#   4. devicectl pulls the AVI from Documents/baseq3/videos/.
#   5. If ffmpeg is installed, we transcode to .mp4 (10×-25× smaller).
#
# Prereqs
#   - iPhone connected via USB, paired, trusted
#   - Q3 build that contains the env-var quality override (the build
#     installed on 2026-06-02 after the MetalFX changes lands)
#   - The user's pak0.pk3 in Documents/baseq3/ (already there)
#   - ffmpeg (optional, for the .mp4 transcode):  brew install ffmpeg
#
# Usage
#   scripts/iphone_q3_quality_avi.sh <quality> [duration_s] [demo_name]
#     quality:    native | high | medium | low      (required)
#     duration:   default 20 (seconds of actual capture)
#     demo_name:  default "four" (Q3 default — Camping Grounds q3dm6)
#
# Overrides (env vars)
#   DEVICE   iPhone device name (default "Yd-Mubarak MajMaj")
#   BUNDLE   app bundle id (default com.quake3ios.app)
#   OUT_DIR  where to drop the AVI/MP4 (default /tmp/q3_avi)
#
# Output
#   $OUT_DIR/q3_<quality>_<HHMMSS>.avi
#   $OUT_DIR/q3_<quality>_<HHMMSS>.mp4    (if ffmpeg available)
#
# Notes
#   - Q3's `video` command ONLY works during demo playback. Map mode does
#     not produce an AVI (CL_Video_f bails). Pass demo names.
#   - The AVI is uncompressed BGR — at iPhone native (2868×1320) each
#     frame is ~11 MB, so 20 s @ 25 fps cl_aviFrameRate ≈ 5.6 GB.
#     Pulling that over USB takes ~30-60 s. The mp4 transcode brings it
#     down to ~50-200 MB.

set -euo pipefail

QUALITY="${1:-}"
DURATION="${2:-20}"
DEMO="${3:-four}"

# ─── arg validation ──────────────────────────────────────────────
if [[ -z "$QUALITY" ]]; then
  echo "usage: $(basename "$0") <quality> [duration_s] [demo_name]" >&2
  echo "  quality: native | high | medium | low" >&2
  exit 1
fi
case "$QUALITY" in
  native|high|medium|low) ;;
  *) echo "ERROR: quality must be native/high/medium/low (got: $QUALITY)" >&2; exit 1 ;;
esac
if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  echo "ERROR: duration must be an integer (got: $DURATION)" >&2; exit 1
fi

DEVICE="${DEVICE:-Yd-Mubarak MajMaj}"
BUNDLE="${BUNDLE:-com.quake3ios.app}"
OUT_DIR="${OUT_DIR:-/tmp/q3_avi}"
mkdir -p "$OUT_DIR"

TS="$(date +%H%M%S)"
VIDEO_NAME="q3_${QUALITY}_${TS}"
AVI_OUT="$OUT_DIR/${VIDEO_NAME}.avi"
MP4_OUT="$OUT_DIR/${VIDEO_NAME}.mp4"
LOG="$OUT_DIR/${VIDEO_NAME}.log"

# ─── timing math ────────────────────────────────────────────────
# Q3 `wait N` is in render frames. Render rate post-MetalFX ≈ 60-120 fps
# on A19 Pro. Use 60 as a conservative average so the wall-clock matches.
RENDER_FPS=60
WAIT_AFTER_DEMO_START=$(( RENDER_FPS * 2 ))     # 2 s settle
FRAMES_TO_CAPTURE=$(( DURATION * RENDER_FPS ))
WAIT_AFTER_RECORD=$(( RENDER_FPS / 3 ))         # ~0.3 s AVI flush

# Wall-clock budget (with safety margin)
WALL_INIT=10                                    # cold Quake3_Init
WALL_TOTAL=$(( WALL_INIT + 2 + DURATION + 2 ))

LAUNCH_CMD="demo ${DEMO}; wait ${WAIT_AFTER_DEMO_START}; video ${VIDEO_NAME}; wait ${FRAMES_TO_CAPTURE}; stopvideo; wait ${WAIT_AFTER_RECORD}"

# ─── execution ──────────────────────────────────────────────────
{
  echo "[avi] device:     $DEVICE"
  echo "[avi] bundle:     $BUNDLE"
  echo "[avi] quality:    $QUALITY"
  echo "[avi] demo:       $DEMO"
  echo "[avi] capture:    ${DURATION}s (~${FRAMES_TO_CAPTURE} render frames)"
  echo "[avi] cbuf chain: ${LAUNCH_CMD}"
  echo "[avi] avi out:    $AVI_OUT"
  echo "[avi] wall total: ${WALL_TOTAL}s"
} | tee "$LOG"

# Terminate any existing instance (idempotent on first run).
echo "[1/4] terminate prior instance..." | tee -a "$LOG"
xcrun devicectl device process terminate \
    --device "$DEVICE" \
    --process com.quake3ios.app 2>/dev/null || true
sleep 1

echo "[2/4] launch Q3 with env override..." | tee -a "$LOG"
# JSON: keys/values double-quoted, internal quotes/backslashes escaped.
ENV_JSON=$(cat <<EOF
{"Q3_UPSCALE_QUALITY":"$QUALITY","Q3_LAUNCH_COMMAND":"$LAUNCH_CMD"}
EOF
)
xcrun devicectl device process launch \
    --device "$DEVICE" \
    --environment-variables "$ENV_JSON" \
    "$BUNDLE" 2>&1 | tee -a "$LOG"

echo "[3/4] wait ${WALL_TOTAL}s for init + demo + capture + flush..." | tee -a "$LOG"
sleep "$WALL_TOTAL"

# Close the AVI cleanly by terminating the app.
xcrun devicectl device process terminate \
    --device "$DEVICE" \
    --process com.quake3ios.app 2>/dev/null || true
sleep 2

echo "[4/4] pull AVI from device..." | tee -a "$LOG"
if ! xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" \
    --source "Documents/baseq3/videos/${VIDEO_NAME}.avi" \
    --destination "$AVI_OUT" 2>&1 | tee -a "$LOG"; then
  echo "[ERROR] failed to pull AVI from device — did the demo play?" | tee -a "$LOG"
  echo "        (verify Documents/baseq3/videos/ contains an AVI for this run)" >&2
  exit 1
fi

if [[ ! -f "$AVI_OUT" ]]; then
  echo "[ERROR] AVI not present at $AVI_OUT after pull" >&2
  exit 1
fi

AVI_SZ=$(du -h "$AVI_OUT" | awk '{print $1}')
echo "[done] AVI: $AVI_OUT ($AVI_SZ)" | tee -a "$LOG"

# Optional ffmpeg transcode to .mp4 (smaller, viewable in QuickTime).
if command -v ffmpeg >/dev/null 2>&1; then
  echo "[opt] transcoding to MP4 via ffmpeg..." | tee -a "$LOG"
  ffmpeg -hide_banner -loglevel warning -y -i "$AVI_OUT" \
      -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
      -movflags +faststart \
      "$MP4_OUT" 2>&1 | tee -a "$LOG"
  if [[ -f "$MP4_OUT" ]]; then
    MP4_SZ=$(du -h "$MP4_OUT" | awk '{print $1}')
    echo "[done] MP4: $MP4_OUT ($MP4_SZ)" | tee -a "$LOG"
  fi
else
  echo "[hint] install ffmpeg to auto-transcode AVI → MP4:  brew install ffmpeg" | tee -a "$LOG"
fi

echo "[summary] outputs in $OUT_DIR/" | tee -a "$LOG"
ls -la "$OUT_DIR" | grep "$TS" | tee -a "$LOG"
