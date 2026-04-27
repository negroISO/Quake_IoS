#!/usr/bin/env zsh
# q3dev_run_ioq3.sh — sibling of q3dev_run.sh, but for the ioq3 reference
# build (com.tomkiddcog.Quake3-iOS). Same iPad, same demo, same autoexec
# pushed from the same Resources/baseq3/ tree, so the two apps boot in the
# closest-to-identical state we can manage. Pulls qconsole.log AND the demo
# AVI from the app sandbox at the end. Output lands under
# ~/Desktop/q3sim_sessions/<timestamp>__<sha>_<slug>_ioq3/ — same layout as
# q3dev_run.sh, but with the _ioq3 suffix so the two runs can be diffed
# cleanly.
#
# Override slug:    q3dev_run_ioq3.sh my-label
# Override device:  DEVICE=<UUID> q3dev_run_ioq3.sh my-label
# Override demo:    DEMO=q3dm4 q3dev_run_ioq3.sh q3dm4-ref
# Override runtime: RUN_SECS=25 q3dev_run_ioq3.sh
#
# Pitfall: both the Metal build and the ioq3 build produce a target named
# "Quake3-iOS.app" — picking the .app by name+mtime alone is ambiguous.
# This script reads CFBundleIdentifier inside each candidate Info.plist
# and keeps only the one matching $BUNDLE_ID, then sorts by mtime.

set -euo pipefail

BUNDLE_ID="com.tomkiddcog.Quake3-iOS"
RUN_SECS="${RUN_SECS:-25}"
DEMO="${DEMO:-q3dm4}"
VIDEO_NAME="${VIDEO_NAME:-$DEMO}"
LAUNCH_COMMAND="${LAUNCH_COMMAND:-demo $DEMO; wait 50; video $VIDEO_NAME; wait 600; stopvideo; quit}"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}"

# Pick newest Debug-iphoneos Quake3-iOS.app whose CFBundleIdentifier matches
# our target bundle. Skip Index.noindex (Xcode's source-indexer build).
APP=$(/usr/bin/find "$DERIVED" -maxdepth 6 -type d -name "Quake3-iOS.app" \
        -path "*Debug-iphoneos*" -not -path "*Index.noindex*" 2>/dev/null \
        | while read -r p; do
            bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                   "$p/Info.plist" 2>/dev/null) || continue
            [[ "$bid" == "$BUNDLE_ID" ]] || continue
            echo "$(/usr/bin/stat -f '%m' "$p") $p"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-)
[[ -z "$APP" ]] && { echo "ERR: no Debug-iphoneos .app for $BUNDLE_ID — build the ioq3 target first" >&2; exit 1; }

if [[ -z "${DEVICE:-}" ]]; then
    DEVICE=$(xcrun devicectl list devices 2>&1 \
              | grep -E 'connected.*(iPhone|iPad)' \
              | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
              | head -1)
fi
[[ -z "$DEVICE" ]] && { echo "ERR: no connected iPhone/iPad; plug in via USB" >&2; exit 1; }

cd "${0:a:h}/.."                                # repo root (Quake_ios)
SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s | tr '[:upper:]' '[:lower:]')
SLUG="${1:-$(echo "$SUBJECT" \
                | sed -E 's/^[a-z]+(\([^)]+\))?: *//' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
                | cut -c1-40)}"
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Desktop/q3sim_sessions/${STAMP}__${SHA}_${SLUG}_ioq3"
mkdir -p "$OUTDIR"
echo "→ logs:    $OUTDIR"
echo "→ device:  $DEVICE"
echo "→ bundle:  $BUNDLE_ID"
echo "→ app:     $APP"
echo "→ runtime: ${RUN_SECS}s"
echo "→ command: $LAUNCH_COMMAND"

# Reinstall to flush any prior crash state.
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1
echo "→ installed"

# Assemble autoexec.cfg on the fly: cvars from Resources/baseq3/autoexec.cfg
# + the demo/video LAUNCH_COMMAND sequence. The ioq3 build (unlike the Metal
# build) does NOT read Q3_LAUNCH_COMMAND from the environment, so the only
# way to autostart the demo at boot is via autoexec.cfg. cfg files are
# semicolon-or-newline delimited at the cbuf level, so we just split on ';'
# and emit one command per line.
AUTOEXEC_BASE="Resources/baseq3/autoexec.cfg"
TMP_CFG=$(mktemp -t q3dev_ioq3_autoexec)
trap "rm -f '$TMP_CFG'" EXIT INT TERM
if [[ -f "$AUTOEXEC_BASE" ]]; then
    cat "$AUTOEXEC_BASE" >> "$TMP_CFG"
    echo "" >> "$TMP_CFG"
fi
echo "// === appended by q3dev_run_ioq3.sh from LAUNCH_COMMAND ===" >> "$TMP_CFG"
# CRITICAL: autoexec.cfg runs DURING Com_Init's cvar phase, BEFORE CL_Init
# registers the "demo" command. Issuing "demo q3dm4" directly here yields
# "Unknown command demo". The fix is `wait N` — Cbuf_Execute exits on wait
# and resumes on the next Com_Frame call (well after CL_Init has run), so
# "demo" is registered by then. 30 frames is ~0.5s of safety margin.
echo "wait 30" >> "$TMP_CFG"
echo "$LAUNCH_COMMAND" | tr ';' '\n' | sed 's/^[[:space:]]*//' >> "$TMP_CFG"
xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$TMP_CFG" \
    --destination "Documents/baseq3/autoexec.cfg" >/dev/null 2>&1 \
    && echo "→ cfg:     pushed assembled autoexec.cfg ($(wc -l < "$TMP_CFG") lines)"

# Push demos. Idempotent overwrite via devicectl copy-to.
DEMO_DIR="Resources/baseq3/demos"
if [[ -d "$DEMO_DIR" ]]; then
    for d in "$DEMO_DIR"/*.dm_68(N) "$DEMO_DIR"/*.dm_73(N); do
        [[ -f "$d" ]] || continue
        xcrun devicectl device copy to --device "$DEVICE" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "$d" \
            --destination "Documents/baseq3/demos/${d:t}" >/dev/null 2>&1 \
            && echo "→ demo:    pushed ${d:t}"
    done
fi

# Launch with --console so the app's stdout streams back over USB.
xcrun devicectl device process launch \
    --device "$DEVICE" \
    --environment-variables "{\"Q3_LAUNCH_COMMAND\":\"$LAUNCH_COMMAND\"}" \
    --console "$BUNDLE_ID" \
    > "$OUTDIR/stdout.log" 2>&1 &
LAUNCH_PID=$!
echo "→ launched (wrapper pid $LAUNCH_PID)"

trap "kill -TERM $LAUNCH_PID 2>/dev/null || true" EXIT INT TERM

sleep "$RUN_SECS"
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
sleep 2

LINES=$(wc -l < "$OUTDIR/stdout.log")
echo "→ stdout:  $LINES lines"

# Pull qconsole.log first — it's small, near-zero risk, and is the whole
# point of this script. Pull it even on a wedged run; the truncated log is
# still useful for "what got far enough to crash" diagnostics.
if xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/baseq3/qconsole.log" \
    --destination "$OUTDIR/qconsole.log" >/dev/null 2>&1; then
    QC_LINES=$(wc -l < "$OUTDIR/qconsole.log" 2>/dev/null || echo 0)
    echo "→ qlog:    $OUTDIR/qconsole.log ($QC_LINES lines)"
else
    echo "→ qlog:    FAILED to pull (is logfile cvar set? did the engine init?)"
fi

# Pull AVI — same gate as q3dev_run.sh.
if [[ $LINES -lt 2000 ]]; then
    echo "→ avi:     SKIPPED (only $LINES stdout lines — looks like a wedged or short run)"
else
    if xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "Documents/baseq3/videos/${VIDEO_NAME}.avi" \
        --destination "$OUTDIR/${VIDEO_NAME}.avi" >/dev/null 2>&1; then
        AVI_SIZE=$(/usr/bin/stat -f '%z' "$OUTDIR/${VIDEO_NAME}.avi")
        AVI_MB=$((AVI_SIZE / 1024 / 1024))
        echo "→ avi:     $OUTDIR/${VIDEO_NAME}.avi (${AVI_MB} MB)"
    else
        echo "→ avi:     FAILED to pull (no ${VIDEO_NAME}.avi on device — video cbuf disabled?)"
    fi
fi
