#!/usr/bin/env bash
# q3_iphone_demo_avi.sh — single-shot capture combining:
#   (1) xctrace Metal System Trace
#   (2) Q3 built-in AVI screen recorder (writes to Documents/baseq3/videos/)
#   (3) Pull resulting AVI from device to host
#
# Sequence:
#   T=0   devicectl launches app with a chained Cbuf in Q3_LAUNCH_COMMAND
#   T=B   Q3 finishes init, executes chain: map <name>; wait N; video <id>; wait M; stopvideo
#   T=B+W xctrace attaches (W = WARMUP seconds, default 10)
#   T=...  xctrace records for SECONDS seconds (default 15)
#   T=end Sleep AVI_TAIL extra seconds for stopvideo to fire and AVI to flush
#   T=end Pull AVI from device
#
# Usage:
#   scripts/q3_iphone_demo_avi.sh                   # q3dm4, 15s
#   scripts/q3_iphone_demo_avi.sh q3dm4 15
#   scripts/q3_iphone_demo_avi.sh q3dm11 20
#   DEVICE="Oled" scripts/q3_iphone_demo_avi.sh q3dm4 15
#
# Output:
#   /tmp/q3_trace/q3iphone_<map>_<HHMMSS>.trace
#   /tmp/q3_trace/q3iphone_<map>_<HHMMSS>.avi
#   /tmp/q3_trace/q3iphone_<map>_<HHMMSS>.log

set -euo pipefail

DEVICE="${DEVICE:-Yd-Mubarak MajMaj}"
BUNDLE="${BUNDLE:-com.quake3ios.app}"
TRACE_DIR="${TRACE_DIR:-/tmp/q3_trace}"
TIMESTAMP="$(date +%H%M%S)"

ARG_MAP="${1:-demo:q3dm4}"
ARG_SECONDS="${2:-15}"

# Demo vs. map mode — Q3's `video` command only works while playing a demo
# (cl_main.c CL_Video_f bails with "can only be used when playing back demos"
# unless clc.demoplaying is true). So if the user wants AVI output they MUST
# launch with `demo <name>` instead of `map <name>`.
# Shortcuts:
#   demo:q3dm4   -> demo q3dm4   (loads baseq3/demos/q3dm4.dm_68)
#   q3dm4        -> map  q3dm4   (no AVI possible — script will warn)
if [[ "$ARG_MAP" == demo:* ]]; then
  LOAD_VERB="demo"
  ARG_NAME="${ARG_MAP#demo:}"
else
  LOAD_VERB="map"
  ARG_NAME="$ARG_MAP"
fi

# Engine-frame waits are render-frame counts, not wall seconds.
# Observed iPhone 17 Pro Max in-game render rate: ~37 fps.
# Cbuf chain timings (all in render frames):
#   wait 90  ≈ 2.4 s  (level transition + first few frames)
#   wait 700 ≈ 19 s   (AVI recording duration — must outlast xctrace window)
WAIT_AFTER_MAP="${WAIT_AFTER_MAP:-90}"
# 25 wait frames per second at cl_aviFrameRate 25.
# Allow override via env, otherwise scale to ARG_SECONDS so the in-engine
# `wait N` after `video` matches the wall-clock capture window.
WAIT_FOR_VIDEO="${WAIT_FOR_VIDEO:-$((ARG_SECONDS * 25))}"

WARMUP="${WARMUP:-10}"
AVI_TAIL="${AVI_TAIL:-8}"

VIDEO_NAME="${ARG_NAME}_${TIMESTAMP}"
LABEL="${ARG_NAME}"

TRACE_OUT="${TRACE_DIR}/q3iphone_${LABEL}_${TIMESTAMP}.trace"
AVI_OUT="${TRACE_DIR}/q3iphone_${LABEL}_${TIMESTAMP}.avi"
LOG="${TRACE_DIR}/q3iphone_${LABEL}_${TIMESTAMP}.log"
mkdir -p "$TRACE_DIR"

LAUNCH_CMD="${LOAD_VERB} ${ARG_NAME}; wait ${WAIT_AFTER_MAP}; video ${VIDEO_NAME}; wait ${WAIT_FOR_VIDEO}; stopvideo"
if [[ "$LOAD_VERB" == "map" ]]; then
  echo "[q3_demo_avi] WARNING: map mode does NOT produce an AVI — Q3's video command requires demo playback. Use demo:<name> to fix." >&2
fi

{
  echo "[q3_demo_avi] device:    $DEVICE"
  echo "[q3_demo_avi] bundle:    $BUNDLE"
  echo "[q3_demo_avi] map:       $ARG_MAP"
  echo "[q3_demo_avi] xctrace:   ${ARG_SECONDS}s"
  echo "[q3_demo_avi] warmup:    ${WARMUP}s"
  echo "[q3_demo_avi] avi_tail:  ${AVI_TAIL}s (lets engine fire stopvideo before pull)"
  echo "[q3_demo_avi] launchcmd: $LAUNCH_CMD"
  echo "[q3_demo_avi] trace:     $TRACE_OUT"
  echo "[q3_demo_avi] avi:       $AVI_OUT"
  echo "[q3_demo_avi] video id:  $VIDEO_NAME"
  echo ""
} | tee "$LOG"

# Step 1: launch
LAUNCH_JSON=$(python3 -c "import json,sys; print(json.dumps({'Q3_LAUNCH_COMMAND': sys.argv[1]}))" "$LAUNCH_CMD")
LAUNCH_JSON_OUT="${TRACE_DIR}/launch_${TIMESTAMP}.json"

echo "[q3_demo_avi] launching app..." | tee -a "$LOG"
xcrun devicectl device process launch \
  --device "$DEVICE" \
  --terminate-existing \
  --environment-variables "$LAUNCH_JSON" \
  --json-output "$LAUNCH_JSON_OUT" \
  "$BUNDLE" >> "$LOG" 2>&1

PID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['result']['process']['processIdentifier'])" "$LAUNCH_JSON_OUT" 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
  echo "[q3_demo_avi] ERROR: no PID from devicectl" | tee -a "$LOG"
  cat "$LAUNCH_JSON_OUT" | tee -a "$LOG"
  exit 1
fi
echo "[q3_demo_avi] PID=$PID" | tee -a "$LOG"

# Step 2: warmup
echo "[q3_demo_avi] warmup ${WARMUP}s..." | tee -a "$LOG"
sleep "$WARMUP"

# Step 3: xctrace
echo "[q3_demo_avi] attaching xctrace for ${ARG_SECONDS}s..." | tee -a "$LOG"
xcrun xctrace record \
  --template "Metal System Trace" \
  --device "$DEVICE" \
  --time-limit "${ARG_SECONDS}s" \
  --output "$TRACE_OUT" \
  --attach "$PID" 2>&1 | tee -a "$LOG"

# Step 4: let AVI finish writing
echo "[q3_demo_avi] xctrace done; waiting ${AVI_TAIL}s for stopvideo + AVI flush..." | tee -a "$LOG"
sleep "$AVI_TAIL"

# Step 5: pull AVI from device app container
echo "[q3_demo_avi] pulling AVI from device..." | tee -a "$LOG"
PULL_OK=0
xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source "Documents/baseq3/videos/${VIDEO_NAME}.avi" \
  --destination "$AVI_OUT" 2>&1 | tee -a "$LOG" && PULL_OK=1 || true

# Step 6: refresh stable "latest" copies
rm -rf "${TRACE_DIR}/q3iphone_latest.trace"
cp -R "$TRACE_OUT" "${TRACE_DIR}/q3iphone_latest.trace" 2>/dev/null || true
if [[ -f "$AVI_OUT" ]]; then
  cp "$AVI_OUT" "${TRACE_DIR}/q3iphone_latest.avi" 2>/dev/null || true
fi

echo "" | tee -a "$LOG"
echo "[q3_demo_avi] done." | tee -a "$LOG"
echo "  trace: $TRACE_OUT" | tee -a "$LOG"
if [[ $PULL_OK -eq 1 && -f "$AVI_OUT" ]]; then
  SZ=$(stat -f %z "$AVI_OUT" 2>/dev/null || echo "?")
  echo "  avi:   $AVI_OUT  (${SZ} bytes)" | tee -a "$LOG"
else
  echo "  avi:   NOT PULLED — check log; the in-app path may not have been written yet" | tee -a "$LOG"
fi
echo "  log:   $LOG"
