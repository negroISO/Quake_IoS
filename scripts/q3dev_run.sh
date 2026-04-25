#!/usr/bin/env zsh
# Run the Quake3-iOS app on the connected physical iPhone, capture
# stdout via devicectl --console, and pull baseq3/videos/four.avi
# out of the app sandbox at the end. Output lands under
# ~/Desktop/q3sim_sessions/<timestamp>__<shortSha>_<slug>/
# alongside what q3sim_run.sh produces — same directory layout so
# downstream tooling (q3vision_diff.py, etc.) doesn't care.
#
# Assumes:
#   - Debug-iphoneos .app already built + signed for this device
#   - The device is plugged in via USB and shows up as "connected"
#     in `xcrun devicectl list devices`
#   - iOS dev image is already mounted (devicectl handles this on
#     first contact each session)
#
# Override slug:    q3dev_run.sh my-label
# Override device:  DEVICE=<UUID> q3dev_run.sh my-label
# Override runtime: RUN_SECS=120 q3dev_run.sh
#                   The boot cbuf records ~75s of demo-four; default
#                   90s gives the demo a chance to finish before we
#                   SIGTERM the launch wrapper.

set -euo pipefail

BUNDLE_ID="com.quake3ios.app"
RUN_SECS="${RUN_SECS:-90}"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}"
APP=$(/usr/bin/find "$DERIVED" -maxdepth 6 -type d -name "Quake3-iOS.app" \
        -path "*Debug-iphoneos*" 2>/dev/null | head -1)
[[ -z "$APP" ]] && { echo "ERR: Debug-iphoneos .app not found — build for device first" >&2; exit 1; }

if [[ -z "${DEVICE:-}" ]]; then
    # Match lines like:
    #   Yd-Mubarak MajMaj  Yd-Mubarak-MajMaj.coredevice.local  <UUID>  connected  iPhone 17 Pro Max (iPhone18,2)
    # Device names contain spaces so positional awk doesn't work — pull
    # the 36-char UUID with grep -oE instead, gated on "connected" + "iPhone".
    DEVICE=$(xcrun devicectl list devices 2>&1 \
              | grep -E 'connected.*iPhone' \
              | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
              | head -1)
fi
[[ -z "$DEVICE" ]] && { echo "ERR: no connected iPhone; plug in via USB" >&2; exit 1; }

cd "${0:a:h}/.."                                # repo root
SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s | tr '[:upper:]' '[:lower:]')
SLUG="${1:-$(echo "$SUBJECT" \
                | sed -E 's/^[a-z]+(\([^)]+\))?: *//' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
                | cut -c1-40)}"
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Desktop/q3sim_sessions/${STAMP}__${SHA}_${SLUG}_dev"
mkdir -p "$OUTDIR"
echo "→ logs:   $OUTDIR"
echo "→ device: $DEVICE"
echo "→ runtime: ${RUN_SECS}s"

# Reinstall to flush any prior crash state. devicectl install is
# idempotent and atomic; on second run it overwrites in place.
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1
echo "→ installed"

# Launch with --console so the app's stdout streams back over USB.
# We background the launch wrapper and SIGTERM it after RUN_SECS;
# the on-device process keeps running until iOS reaps it (which
# happens within a couple of seconds of the wrapper closing).
xcrun devicectl device process launch \
    --device "$DEVICE" \
    --console com.quake3ios.app \
    > "$OUTDIR/stdout.log" 2>&1 &
LAUNCH_PID=$!
echo "→ launched (wrapper pid $LAUNCH_PID)"

trap "kill -TERM $LAUNCH_PID 2>/dev/null || true" EXIT INT TERM

sleep "$RUN_SECS"
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
sleep 2

LINES=$(wc -l < "$OUTDIR/stdout.log")
echo "→ stdout: $LINES lines"

# Pull four.avi out of the app sandbox via devicectl. Path is
# Documents/baseq3/videos/four.avi inside appDataContainer.
# Same gates as the sim path: skip if no AVI / wedged run.
if [[ $LINES -lt 2000 ]]; then
    echo "→ avi:    SKIPPED (only $LINES stdout lines — looks like a wedged or short run)"
else
    if xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents/baseq3/videos/four.avi \
        --destination "$OUTDIR/four.avi" >/dev/null 2>&1; then
        AVI_SIZE=$(/usr/bin/stat -f '%z' "$OUTDIR/four.avi")
        AVI_MB=$((AVI_SIZE / 1024 / 1024))
        echo "→ avi:    $OUTDIR/four.avi (${AVI_MB} MB)"
    else
        echo "→ avi:    FAILED to pull (no four.avi on device — video cbuf disabled?)"
    fi
fi
