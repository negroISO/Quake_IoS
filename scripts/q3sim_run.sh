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

xcrun simctl launch --console-pty "$SIM" "$BUNDLE_ID" > "$OUTDIR/stdout.log" 2>&1
echo "→ stdout: $(wc -l < "$OUTDIR/stdout.log") lines, syslog: $(wc -l < "$OUTDIR/syslog.log") lines"
