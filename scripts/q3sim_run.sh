#!/usr/bin/env zsh
# Run the Quake3-iOS app on the booted Apple Silicon simulator,
# capture stdout + unified syslog, and stash both under
# ~/Desktop/q3sim_sessions/<timestamp>__<shortSha>_<slug>/
#
# Assumes:
#   - Debug-iphonesimulator .app already built (arm64)
#   - A simulator device is currently Booted (first match wins)
#
# Override slug with: q3sim_run.sh my-label

set -euo pipefail

BUNDLE_ID="com.quake3ios.app"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}"
APP=$(/usr/bin/find "$DERIVED" -maxdepth 6 -type d -name "Quake3-iOS.app" \
        -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)
[[ -z "$APP" ]] && { echo "ERR: Debug-iphonesimulator .app not found" >&2; exit 1; }

SIM=$(xcrun simctl list devices booted 2>/dev/null \
       | awk '/\(Booted\)/ {match($0, /[0-9A-F-]{36}/); print substr($0,RSTART,RLENGTH); exit}')
[[ -z "$SIM" ]] && { echo "ERR: no Booted simulator; open Simulator.app first" >&2; exit 1; }

cd "${0:a:h}/.."                                # repo root
SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s | tr '[:upper:]' '[:lower:]')
SLUG="${1:-$(echo "$SUBJECT" \
                | sed -E 's/^[a-z]+(\([^)]+\))?: *//' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
                | cut -c1-40)}"
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Desktop/q3sim_sessions/${STAMP}__${SHA}_${SLUG}"
mkdir -p "$OUTDIR"
echo "→ logs: $OUTDIR"

xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
# Settle: SimMetalHost XPC bridge races if install fires immediately
# after terminate, aborting the first launch inside
# -[MTLSimDevice newTextureWithDescriptor:...] with
# MTLCommandBufferErrorDomain error 1 before any user code runs.
sleep 1
xcrun simctl install   "$SIM" "$APP"
xcrun simctl spawn "$SIM" log stream --style compact \
    --predicate 'processImagePath CONTAINS "Quake3-iOS" OR senderImagePath CONTAINS "Quake3-iOS"' \
    > "$OUTDIR/syslog.log" 2>&1 &
SYSPID=$!
trap "kill $SYSPID 2>/dev/null || true" EXIT INT TERM

# Capture pre-run epoch so we can tell whether the AVI under the
# sim's data container is fresh (this run) or a leftover from a
# previous run that the failing-then-relaunched app never overwrote.
RUN_START_EPOCH=$(date +%s)

xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" > "$OUTDIR/stdout.log" 2>&1
LINES=$(wc -l < "$OUTDIR/stdout.log")
echo "→ stdout: $LINES lines, syslog: $(wc -l < "$OUTDIR/syslog.log") lines"

# Bundle the captured AVI alongside the logs IF it's actually from
# this run. The boot cbuf records `video four; wait 1500; stopvideo`
# to baseq3/videos/four.avi inside the sim's per-install data
# container. Two failure modes to guard against:
#   1. Stale AVI: SimMetalHost XPC wedge can crash the app before
#      demo playback; an old four.avi from a prior good run will
#      still be on disk and look "freshly modified" relative to
#      this run start. mtime gate filters it out.
#   2. Truncated run: the cbuf takes ~75s to reach `stopvideo`. A
#      successful run produces ~9500+ stdout lines; anything <2000
#      means we never reached gameplay.
SIM_ROOT="$HOME/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Data/Application"
LATEST_AVI=$(/usr/bin/find "$SIM_ROOT" -name four.avi 2>/dev/null \
              | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
              | sort -rn | head -1 | cut -d' ' -f2-)
if [[ -z "$LATEST_AVI" || ! -f "$LATEST_AVI" ]]; then
    echo "→ avi:    (no four.avi on disk — video cbuf disabled?)"
elif [[ $LINES -lt 2000 ]]; then
    echo "→ avi:    SKIPPED (only $LINES stdout lines — looks like a wedged run)"
else
    AVI_MTIME=$(/usr/bin/stat -f '%m' "$LATEST_AVI")
    if (( AVI_MTIME < RUN_START_EPOCH )); then
        echo "→ avi:    SKIPPED (mtime $AVI_MTIME < run start $RUN_START_EPOCH; stale)"
    else
        cp "$LATEST_AVI" "$OUTDIR/four.avi"
        AVI_SIZE=$(/usr/bin/stat -f '%z' "$OUTDIR/four.avi")
        AVI_MB=$((AVI_SIZE / 1024 / 1024))
        echo "→ avi:    $OUTDIR/four.avi (${AVI_MB} MB)"
    fi
fi
