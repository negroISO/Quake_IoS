#!/usr/bin/env bash
# q3_iphone_trace.sh — launch Quake3-iOS on a connected iPhone (or any
# Apple device available via devicectl) and attach a headless Metal
# System Trace via xctrace.
#
# Workaround for iPadOS/iOS 26.5 + Xcode 26 xctrace --launch regression
# (mirrors scripts/ipad_demo_trace.sh from the Q2 project).
#
# Usage:
#   scripts/q3_iphone_trace.sh                          # 30s on q3dm1
#   scripts/q3_iphone_trace.sh q3dm6 45                 # 45s on q3dm6
#   scripts/q3_iphone_trace.sh "map q3dm1; +set r_subdivisions 4" 30
#   DEVICE="Oled" scripts/q3_iphone_trace.sh q3dm17 45  # iPad instead
#
# Output:
#   /tmp/q3_trace/q3iphone_<label>_<HHMMSS>.trace
#   /tmp/q3_trace/q3iphone_latest.trace  (stable copy for quick re-open)
#
# Open after capture:
#   open /tmp/q3_trace/q3iphone_latest.trace

set -euo pipefail

DEVICE="${DEVICE:-Yd-Mubarak MajMaj}"
BUNDLE="${BUNDLE:-com.quake3ios.app}"
TRACE_DIR="${TRACE_DIR:-/tmp/q3_trace}"
TIMESTAMP="$(date +%H%M%S)"

# arg1 = launch target — either a bare map name, a `demo:NAME` shortcut,
#        or a full Cbuf string (must be quoted)
# Examples:
#   q3dm1                 -> map q3dm1
#   demo:four             -> demo four          (recorded gameplay - exercises tcMod/fog/deform)
#   "demo four"           -> demo four          (same; quoted form)
#   "map q3dm4; +wait 60" -> verbatim
ARG_TARGET="${1:-q3dm1}"
ARG_SECONDS="${2:-30}"

# Pre-attach warmup. Default 3s is enough for `+map` (player spawns idle).
# Demos need ~6s to: spawn server, exec demo command, load level, parse
# initial demo frames, and start rendering. Without enough warmup, xctrace
# attaches DURING the loading-screen plaque and captures a static frame.
WARMUP="${WARMUP:-}"

if [[ "$ARG_TARGET" == demo:* ]]; then
  DEMO_NAME="${ARG_TARGET#demo:}"
  LAUNCH_CMD="demo ${DEMO_NAME}"
  LABEL="demo-${DEMO_NAME}"
  : "${WARMUP:=6}"
elif [[ "$ARG_TARGET" =~ ^[A-Za-z0-9_]+$ ]]; then
  LAUNCH_CMD="map ${ARG_TARGET}"
  LABEL="${ARG_TARGET}"
  : "${WARMUP:=3}"
else
  LAUNCH_CMD="$ARG_TARGET"
  LABEL="custom"
  : "${WARMUP:=4}"
fi

OUTPUT="${TRACE_DIR}/q3iphone_${LABEL}_${TIMESTAMP}.trace"
mkdir -p "$TRACE_DIR"

echo "[q3_trace] device:   $DEVICE"
echo "[q3_trace] bundle:   $BUNDLE"
echo "[q3_trace] launch:   $LAUNCH_CMD"
echo "[q3_trace] seconds:  $ARG_SECONDS"
echo "[q3_trace] output:   $OUTPUT"
echo ""

# Step 1: launch app on device with the launch command in the env var
#   the SwiftUI shell reads (Quake3_iOSApp.swift looks for Q3_LAUNCH_COMMAND)
LAUNCH_JSON=$(python3 -c "import json,sys; print(json.dumps({'Q3_LAUNCH_COMMAND': sys.argv[1]}))" "$LAUNCH_CMD")

echo "[q3_trace] launching app on device..."
# Xcode 26 / iOS 26.5: devicectl no longer prints "PID: NNNN" in plain
# text output. Pull processIdentifier from the structured JSON instead.
LAUNCH_JSON_OUT="${TRACE_DIR}/launch_${TIMESTAMP}.json"
xcrun devicectl device process launch \
  --device "$DEVICE" \
  --terminate-existing \
  --environment-variables "$LAUNCH_JSON" \
  --json-output "$LAUNCH_JSON_OUT" \
  "$BUNDLE"

PID="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['result']['process']['processIdentifier'])" "$LAUNCH_JSON_OUT" 2>/dev/null || true)"
if [[ -z "$PID" || "$PID" == "None" ]]; then
  echo "[q3_trace] ERROR: could not parse PID from devicectl JSON; dump:" >&2
  cat "$LAUNCH_JSON_OUT" >&2
  exit 1
fi
echo "[q3_trace] app PID: $PID"

# Give the engine some warmup before attaching xctrace so the trace captures
# in-game frames, not loading-screen plaque frames. Override via WARMUP=8.
echo "[q3_trace] warmup ${WARMUP}s for engine to reach in-game frames..."
sleep "$WARMUP"

# Step 2: attach xctrace
#  NOTE: device screen MUST be on/unlocked or xctrace will silently stall.
echo "[q3_trace] attaching xctrace --template 'Metal System Trace'..."
xcrun xctrace record \
  --template "Metal System Trace" \
  --device "$DEVICE" \
  --time-limit "${ARG_SECONDS}s" \
  --output "$OUTPUT" \
  --attach "$PID"

# Stable "latest" copy for quick `open` re-runs. Remove first because
# `cp -R src dest` (where dest is an existing dir) NESTS src inside dest
# — .trace bundles look like dirs to cp.
rm -rf "${TRACE_DIR}/q3iphone_latest.trace"
cp -R "$OUTPUT" "${TRACE_DIR}/q3iphone_latest.trace" 2>/dev/null || true

echo ""
echo "[q3_trace] capture complete:"
echo "  $OUTPUT"
echo ""
echo "Open with:    open '$OUTPUT'"
echo "Stable copy:  open '${TRACE_DIR}/q3iphone_latest.trace'"
