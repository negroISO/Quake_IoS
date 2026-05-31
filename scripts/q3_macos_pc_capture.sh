#!/usr/bin/env bash
# q3_macos_pc_capture.sh — Quake3e Vulkan reference capture on macOS.
#
# Records a demo + AVI from frame 0 (no manually-typed console commands)
# so we have a clean PC reference to compare against the iOS Metal port.
#
# Trick: writes a temp .cfg into baseq3/ with the demo+video+stopvideo+quit
# chain, then launches Quake3e with `+exec <cfg>`. Because the chain runs
# from a cbuf script (not from `+wait` chained on cmdline), wait semantics
# behave the way they're supposed to and the video command fires on the
# same frame the demo starts rendering.
#
# Usage:
#   scripts/q3_macos_pc_capture.sh                    # q3dm4, 30s of AVI
#   scripts/q3_macos_pc_capture.sh q3dm4 30
#   scripts/q3_macos_pc_capture.sh four 45            # stock CTF demo
#   QUAKE3E=/path/to/quake3e scripts/q3_macos_pc_capture.sh q3dm4
#
# Output:
#   /tmp/q3_trace/<demo>_pc_<HHMMSS>.avi
#   /tmp/q3_trace/q3dm4_pc_latest.avi  (stable symlink)
#
# Requirements:
#   - Quake3e binary built with USE_VULKAN=1
#   - .pk3 paks staged at ~/Library/Application Support/Quake3/baseq3/
#   - Demo file staged at ~/Library/Application Support/Quake3/baseq3/demos/<name>.dm_NN

set -euo pipefail

DEMO_NAME="${1:-q3dm4}"
DURATION_SEC="${2:-30}"
QUAKE3E="${QUAKE3E:-$HOME/src/Quake3e/build/release-darwin-arm64/quake3e.arm64}"
HOME_DIR="$HOME/Library/Application Support/Quake3"
BASEQ3="$HOME_DIR/baseq3"
OUT_DIR="${OUT_DIR:-/tmp/q3_trace}"
TIMESTAMP="$(date +%H%M%S)"

# Resolution mode:
#   RES=native   (default) — r_mode -2 = desktop resolution
#   RES=iphone             — r_mode -1 + 960x444 to match iOS Q3_MATCH_PROFILE=metal_960_25
#   RES=ipad               — r_mode -1 + 1280x960 to match Q3_MATCH_PROFILE=metal_1280_25
#   RES=WxH                — explicit, e.g. RES=1920x1080
RES="${RES:-native}"
case "$RES" in
  native)             MODE_ARGS="+set r_mode -2"; RES_TAG="native" ;;
  iphone)             MODE_ARGS="+set r_mode -1 +set r_customwidth 960 +set r_customheight 444"; RES_TAG="960x444" ;;
  ipad)               MODE_ARGS="+set r_mode -1 +set r_customwidth 1280 +set r_customheight 960"; RES_TAG="1280x960" ;;
  *x*)
    W="${RES%x*}"; H="${RES#*x}"
    MODE_ARGS="+set r_mode -1 +set r_customwidth ${W} +set r_customheight ${H}"
    RES_TAG="${W}x${H}"
    ;;
  *) echo "[pc_capture] ERROR: unknown RES=$RES (expected native|iphone|ipad|WxH)"; exit 1 ;;
esac
VIDEO_NAME="${DEMO_NAME}_pc_${RES_TAG}_${TIMESTAMP}"
AVI_OUT="$OUT_DIR/${VIDEO_NAME}.avi"
LOG="$OUT_DIR/${VIDEO_NAME}.log"
LATEST_LINK="$OUT_DIR/q3dm4_pc_latest.avi"

# Recording duration → wait frames. During AVI capture Q3 caps render rate
# to cl_aviFrameRate (we use 25). So wait_frames = duration_sec * 25.
RECORD_FRAMES=$((DURATION_SEC * 25))

# Pre-flight
if [[ ! -x "$QUAKE3E" ]]; then
  echo "[pc_capture] ERROR: Quake3e binary not found at $QUAKE3E"
  echo "    set QUAKE3E=<path> or build: cd ~/src/Quake3e && make ARCH=arm64 USE_VULKAN=1 -j8"
  exit 1
fi
DEMO_FILE=""
for ext in dm_68 dm_71 dm_73; do
  if [[ -f "$BASEQ3/demos/${DEMO_NAME}.${ext}" ]]; then
    DEMO_FILE="$BASEQ3/demos/${DEMO_NAME}.${ext}"; break
  fi
done
if [[ -z "$DEMO_FILE" ]]; then
  echo "[pc_capture] ERROR: demo not found at $BASEQ3/demos/${DEMO_NAME}.dm_*"
  echo "    available demos:"
  ls -1 "$BASEQ3/demos/" 2>/dev/null | sed 's/^/      /'
  exit 1
fi

mkdir -p "$OUT_DIR"

# Drive Q3 through a pseudo-terminal via `expect`. Identical to a human
# typing into the in-engine console (proven to work) but on a shell timer.
#
# Why nothing else worked:
#   - +exec foo.cfg / +set autoaction + +vstr autoaction (cmdline): Q3 joins
#     argv[] back into a single command line with NO quoting preservation.
#     Cvar/cmd values get truncated at the first space.
#   - baseq3/autoexec.cfg: runs DURING Com_Init's early Cbuf_Execute, before
#     CL_Init. The `demo` command isn't registered yet — Q3 prints
#     "Unknown command 'demo'" and bails. See log artifact at
#     /tmp/q3_trace/q3dm4_pc_960x444_133657.log.
#   - fifo on stdin (`< /tmp/foo.fifo`): Quake3e's ttycon explicitly checks
#     isatty(stdin); fails with "stdin is not a tty, tty console mode failed"
#     and disables the console reader. A fifo isn't a TTY device.
#
# expect's spawn allocates a pseudo-terminal which DOES pass isatty(). Then
# we send/sleep/send to inject commands AFTER the engine is fully booted.

# Sanity check: expect must be available
if ! command -v expect >/dev/null 2>&1; then
  echo "[pc_capture] ERROR: expect not found. Install with: brew install expect"
  exit 1
fi

{
  echo "[pc_capture] demo file:  $DEMO_FILE"
  echo "[pc_capture] resolution: $RES_TAG"
  echo "[pc_capture] duration:   ${DURATION_SEC}s  (${RECORD_FRAMES} frames @ 25fps)"
  echo "[pc_capture] driver:     expect (pty)"
  echo "[pc_capture] avi out:    $AVI_OUT"
  echo ""
} | tee "$LOG"

# Launch Quake3e under expect. Q3's ttycon REQUIRES a real TTY (isatty()
# check) — a fifo fails with "stdin is not a tty, tty console mode failed".
# expect allocates a pseudo-terminal via `spawn`, which passes the isatty
# check. Then we send/sleep/send to inject commands at the right moments.
expect <<EXPECT 2>&1 | tee -a "$LOG"
log_user 1
set timeout 120
spawn "$QUAKE3E" \\
  +set cl_renderer vulkan \\
  +set r_renderer vulkan \\
  {*}[split "$MODE_ARGS" " "] \\
  +set r_fullscreen 0 \\
  +set in_mouse 0 \\
  +set s_initsound 0 \\
  +set com_introPlayed 1 \\
  +set cl_introPlayed 1 \\
  +set r_picmip 0 \\
  +set r_skymip 0 \\
  +set r_roundImagesDown 0 \\
  +set r_textureMode GL_LINEAR_MIPMAP_LINEAR \\
  +set r_ext_compress_textures 0 \\
  +set r_detailtextures 1 \\
  +set r_ext_texture_filter_anisotropic 1 \\
  +set r_ext_max_anisotropy 16 \\
  +set r_subdivisions 4 \\
  +set r_lodbias -2 \\
  +set r_lodCurveError 8192 \\
  +set r_lodscale 5 \\
  +set r_vertexLight 0 \\
  +set r_overBrightBits 1 \\
  +set r_mapOverBrightBits 2 \\
  +set r_gamma 1.0 \\
  +set r_intensity 1.0 \\
  +set cg_shadows 3 \\
  +set cg_marks 1 \\
  +set cg_brassTime 10000 \\
  +set r_drawSun 1 \\
  +set r_fastsky 0 \\
  +set r_finish 0 \\
  +set r_textureBits 32 \\
  +set r_depthBits 24 \\
  +set r_stencilBits 8 \\
  +set cl_aviMotionJpeg 1 \\
  +set cl_aviFrameRate 25 \\
  +set com_maxfps 25 \\
  +set com_maxfpsUnfocused 25 \\
  +set ttycon 1

# Wait for menu (engine to print its in-app console prompt "]")
expect {
  -re {Started tty console} { puts "\n\[pc_capture\] tty console up" }
  timeout { puts "\n\[pc_capture\] WARN: timed out waiting for tty console" }
}
sleep 2

puts "\n\[pc_capture\] sending: demo $DEMO_NAME"
send "demo $DEMO_NAME\r"
sleep 3

puts "\n\[pc_capture\] sending: video $VIDEO_NAME"
send "video $VIDEO_NAME\r"
sleep $DURATION_SEC

puts "\n\[pc_capture\] sending: stopvideo"
send "stopvideo\r"
sleep 2

puts "\n\[pc_capture\] sending: quit"
send "quit\r"

# Wait up to 5s for Q3 to actually exit
set timeout 5
expect eof
puts "\n\[pc_capture\] Q3 exited"
EXPECT

# Move AVI to /tmp/q3_trace/ and refresh stable symlink
SRC_AVI="$BASEQ3/videos/${VIDEO_NAME}.avi"
if [[ -f "$SRC_AVI" ]]; then
  mv "$SRC_AVI" "$AVI_OUT"
  SZ=$(stat -f %z "$AVI_OUT" 2>/dev/null || echo "?")
  rm -f "$LATEST_LINK"
  cp "$AVI_OUT" "$LATEST_LINK" 2>/dev/null || true
  echo "" | tee -a "$LOG"
  echo "[pc_capture] DONE  $AVI_OUT  (${SZ} bytes)" | tee -a "$LOG"
  echo "         stable: $LATEST_LINK"
  echo "         log:    $LOG"
else
  echo "[pc_capture] WARN: no AVI was written at $SRC_AVI" | tee -a "$LOG"
  echo "    Q3 console log is captured in $LOG — search for 'demo' / 'video' lines"
  exit 2
fi
