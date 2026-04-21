#!/usr/bin/env bash
# Start/finalize a ~/Desktop/q3sim_sessions/<stamp>_<label>/ folder with
# meta.txt + q3.log + filtered.log + frames/ per simulator iteration.
#
# Usage:
#   q3sim_session.sh start <label>                     # echoes SESSION path + starts log capture
#   q3sim_session.sh frame <session> <idx>             # captures a rotated PNG into frames/
#   q3sim_session.sh finish <session> [<stop_reason>]  # copies log + builds meta.txt
#   q3sim_session.sh autorun <label> [duration_sec]    # full run: launch, 1fps capture,
#                                                      # finish with meta/log. default 25s.
#
# The path is echoed so callers can:
#   SESSION=$(scripts/q3sim_session.sh start my-label)

set -euo pipefail

REPO=/Users/targus/Documents/Quake_IoS
SESSIONS_DIR="$HOME/Desktop/q3sim_sessions"
SIM_UDID="${Q3SIM_UDID:-77575E1E-108A-400D-B844-BCDB8514BE2E}"
BUNDLE_ID="${Q3SIM_BUNDLE:-com.quake3ios.app}"

cmd=${1:-}
shift || true

case "$cmd" in
  start)
    label=${1:?label required}
    stamp=$(date +%Y%m%d_%H%M%S)
    session="$SESSIONS_DIR/${stamp}_${label}"
    mkdir -p "$session/frames"
    # Start a fresh q3 stdout capture in the background; pid stored for finish.
    logpath="$session/q3.log"
    : > "$logpath"
    xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID" >"$logpath" 2>&1 &
    echo $! > "$session/.launch.pid"
    echo "$session"
    ;;

  frame)
    session=${1:?session path required}
    idx=${2:?frame index required}
    raw=$(mktemp /tmp/q3frame_raw.XXXX.png)
    xcrun simctl io "$SIM_UDID" screenshot "$raw" >/dev/null 2>&1
    # Rotate portrait → landscape (engine renders landscape but sim reports portrait)
    sips -r 90 "$raw" --out "$session/frames/frame_$(printf '%03d' "$idx").png" >/dev/null 2>&1 || cp "$raw" "$session/frames/frame_$(printf '%03d' "$idx").png"
    rm -f "$raw"
    ;;

  finish)
    session=${1:?session path required}
    stop_reason=${2:-unspecified}

    # Stop the launch process if it's still running.
    if [[ -f "$session/.launch.pid" ]]; then
      pid=$(cat "$session/.launch.pid")
      kill "$pid" 2>/dev/null || true
      rm -f "$session/.launch.pid"
    fi

    timedemo=$(grep -E '[0-9]+ frames, [0-9.]+ seconds: [0-9.]+ fps' "$session/q3.log" 2>/dev/null | tail -1 || true)

    app_bundle=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" app 2>/dev/null || echo unknown)
    app_data=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || echo unknown)

    {
      echo "# Q3Sim session: $(basename "$session")"
      echo "label=$(basename "$session" | cut -d_ -f3-)"
      echo ""
      echo "## git HEAD"
      (cd "$REPO" && git log --oneline -5)
      echo ""
      echo "## dirty files"
      (cd "$REPO" && git status --short)
      echo ""
      echo "## simulator"
      xcrun simctl list devices booted | grep -v '^--'
      echo "app-bundle=$app_bundle"
      echo "app-data=$app_data"
      echo ""
      echo "## run outcome"
      echo "stop_reason=$stop_reason"
      [[ -n "$timedemo" ]] && echo "timedemo_result=$timedemo"
    } > "$session/meta.txt"

    grep -iE 'metal|skin|entity|light|shader|error|warn' "$session/q3.log" > "$session/filtered.log" 2>/dev/null || true

    echo "[q3sim_session] wrote $session" >&2
    ;;

  autorun)
    label=${1:?label required}
    duration=${2:-25}
    session=$("$0" start "$label")
    # Wait for engine to begin loading the demo before capturing,
    # so frame 001 actually lands inside the gameplay window.
    for ((i=0; i<20; i++)); do
      if grep -q 'Demo file:' "$session/q3.log" 2>/dev/null; then break; fi
      sleep 1
    done
    # Extra buffer: demo file load + map load + first render take a few more seconds.
    sleep 3
    for ((i=1; i<=duration; i++)); do
      "$0" frame "$session" "$i" 2>/dev/null || true
      # Stop early once the engine has cleanly shut down — avoids padding
      # the tail with SpringBoard captures after the demo ends.
      if grep -q -E 'Client Shutdown|Sys_Quit' "$session/q3.log" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    "$0" finish "$session" "autorun-${duration}s" >&2
    echo "$session"
    ;;

  *)
    echo "usage: $0 {start <label> | frame <session> <idx> | finish <session> [<stop_reason>] | autorun <label> [duration_sec]}" >&2
    exit 2
    ;;
esac
