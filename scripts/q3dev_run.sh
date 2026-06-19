#!/usr/bin/env zsh
# Run the Quake3-iOS app on a connected physical device, capture
# stdout via devicectl --console, and pull baseq3/videos/<demo>.avi
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
# Override demo:    DEMO=q3dm4 q3dev_run.sh q3dm4-ipad
# Override video:   VIDEO_NAME=q3dm4 q3dev_run.sh q3dm4-ipad
# Override runtime: RUN_SECS=120 q3dev_run.sh

set -euo pipefail

# --- Catalyst-only guard (added by orchestrator 2026-06-18) ---------------
# The repair loop is Mac Catalyst ONLY. This iPad/device runner kept getting
# invoked by automation and launching on the OLED iPad, which is off-goal and
# trips LaunchServicesDataMismatch. Refuse unless explicitly overridden.
# To intentionally run on device: prefix the command with Q3_ALLOW_DEVICE=1.
if [ "${Q3_ALLOW_DEVICE:-0}" != "1" ]; then
  echo "ERROR: q3dev_run.sh (iPad/device runner) is DISABLED during the Catalyst repair loop." >&2
  echo "       Use ./scripts/q3dev_run_mac.sh <slug>  (Mac Catalyst) instead." >&2
  echo "       To force a real device run anyway: Q3_ALLOW_DEVICE=1 ./scripts/q3dev_run.sh <slug>" >&2
  exit 2
fi
# -------------------------------------------------------------------------

BUNDLE_ID="${BUNDLE_ID:-com.quake3ios.rt}"
RUN_SECS="${RUN_SECS:-90}"
DEMO="${DEMO:-four}"
VIDEO_NAME="${VIDEO_NAME:-$DEMO}"
LAUNCH_COMMAND="${LAUNCH_COMMAND:-demo $DEMO; wait 50; video $VIDEO_NAME; wait 1500; stopvideo; quit}"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}"
# Multiple DerivedData hashes can coexist (one per Xcode-detected workspace
# location); old ones don't get cleaned up. Picking the alphabetical first
# match, like a naive `find … | head -1`, has bitten us with stale April-14
# binaries on April-25 — symptoms: boot cbuf edits don't take effect, builds
# silently use a different binary than xcodebuild produced. Pick by NEWEST
# mtime instead, and skip Index.noindex (Xcode's source-indexer build, not
# the actual install product).
APP=$(/usr/bin/find "$DERIVED" -maxdepth 6 -type d \( -name "Quake3-iOS.app" -o -name "Q3_RT.app" \) \
        -path "*Debug-iphoneos*" -not -path "*Index.noindex*" 2>/dev/null \
        | while read -r p; do
            plist="$p/Info.plist"
            if [[ -f "$plist" ]]; then
                bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)
                if [[ "$bid" == "$BUNDLE_ID" ]]; then
                    echo "$(/usr/bin/stat -f '%m' "$p") $p"
                fi
            fi
          done \
        | sort -rn | head -1 | cut -d' ' -f2-)
[[ -z "$APP" ]] && { echo "ERR: Debug-iphoneos .app for $BUNDLE_ID not found in $DERIVED — build for device first" >&2; exit 1; }

if [[ -z "${DEVICE:-}" ]]; then
    # Match lines like:
    #   Oled  Oled.coredevice.local  <UUID>  connected  iPad Pro 13-inch ...
    # Device names contain spaces so positional awk doesn't work — pull
    # the 36-char UUID with grep -oE instead, gated on "connected" + iOS device.
    DEVICE=$(xcrun devicectl list devices 2>&1 \
              | grep -E 'connected.*(iPhone|iPad)' \
              | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
              | head -1)
fi
[[ -z "$DEVICE" ]] && { echo "ERR: no connected iPhone/iPad; plug in via USB" >&2; exit 1; }

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
echo "→ command: $LAUNCH_COMMAND"

# Reinstall to flush any prior crash state. devicectl install is
# idempotent and atomic, but this bundle is huge; set SKIP_INSTALL=1
# after a successful install when only command-line cvars/maps change.
if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
    echo "→ installed: SKIPPED (SKIP_INSTALL=1)"
else
    xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1
    echo "→ installed"
fi

# Push autoexec.cfg if present. Forces logfile=2/developer=1 so
# qconsole.log captures the boot/shader trace for cross-engine diff
# against q3dev_run_ioq3.sh runs.
AUTOEXEC="Resources/baseq3/autoexec.cfg"
TMP_AUTOEXEC=""
if [[ ! -f "$AUTOEXEC" ]]; then
    TMP_AUTOEXEC=$(mktemp /tmp/q3_autoexec.XXXXXX.cfg)
    cat > "$TMP_AUTOEXEC" <<'CFG'
seta logfile 2
seta developer 1
seta r_logFile 0
seta com_speeds 0
CFG
    AUTOEXEC="$TMP_AUTOEXEC"
fi
xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$AUTOEXEC" \
    --destination "Documents/baseq3/autoexec.cfg" >/dev/null 2>&1 \
    && echo "→ cfg:    pushed autoexec.cfg"
[[ -n "$TMP_AUTOEXEC" ]] && rm -f "$TMP_AUTOEXEC"

# Seed any local demos onto the device. The .app bundle does NOT
# carry baseq3 resources (pk3s ship via Files-app sharing into
# Documents/baseq3/), so demos do too. We push every .dm_68 found
# under Resources/baseq3/demos/ to Documents/baseq3/demos/. Cheap
# and idempotent: devicectl copy-to overwrites in place. On a
# device that already has all demos this is ~free per file.
DEMO_DIR="Resources/baseq3/demos"
if [[ -d "$DEMO_DIR" ]]; then
    for d in "$DEMO_DIR"/*.dm_68(N); do
        [[ -f "$d" ]] || continue
        xcrun devicectl device copy to --device "$DEVICE" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "$d" \
            --destination "Documents/baseq3/demos/${d:t}" >/dev/null 2>&1 \
            && echo "→ demo:    pushed ${d:t}"
    done
fi

# Launch with --console so the app's stdout streams back over USB.
# We background the launch wrapper and SIGTERM it after RUN_SECS;
# the on-device process keeps running until iOS reaps it (which
# happens within a couple of seconds of the wrapper closing).
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
echo "→ stdout: $LINES lines"

# Pull qconsole.log first — small, near-zero risk, the whole point of
# pairing this runner with q3dev_run_ioq3.sh for cross-engine diffing.
# Pulled even on wedged runs (truncated log still tells us how far we got).
if xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/baseq3/qconsole.log" \
    --destination "$OUTDIR/qconsole.log" >/dev/null 2>&1; then
    QC_LINES=$(wc -l < "$OUTDIR/qconsole.log" 2>/dev/null || echo 0)
    echo "→ qlog:   $OUTDIR/qconsole.log ($QC_LINES lines)"
else
    echo "→ qlog:   FAILED to pull (autoexec.cfg pushed? logfile cvar live?)"
fi

# Pull q3_diag.log — C/Swift renderer telemetry lands in Documents/.
if xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/q3_diag.log" \
    --destination "$OUTDIR/q3_diag.log" >/dev/null 2>&1; then
    DIAG_LINES=$(wc -l < "$OUTDIR/q3_diag.log" 2>/dev/null || echo 0)
    echo "→ diag:   $OUTDIR/q3_diag.log ($DIAG_LINES lines)"
fi

# Pull the AVI out of the app sandbox via devicectl. Path is
# Documents/baseq3/videos/<video>.avi inside appDataContainer.
# We only pull when stdout shows a successful write; older runs may leave
# stale files on-device, and older launch-command paths can silently avoid
# recording. stdout is the only reliable signal for a fresh capture.
if grep -qE "Wrote [0-9]+:[0-9]+ frames to videos/${VIDEO_NAME}\\.avi" "$OUTDIR/stdout.log"; then
  if xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/baseq3/videos/${VIDEO_NAME}.avi" \
    --destination "$OUTDIR/${VIDEO_NAME}.avi" >/dev/null 2>&1; then
    AVI_SIZE=$(/usr/bin/stat -f '%z' "$OUTDIR/${VIDEO_NAME}.avi")
    AVI_MB=$((AVI_SIZE / 1024 / 1024))
    echo "→ avi:    $OUTDIR/${VIDEO_NAME}.avi (${AVI_MB} MB)"
    if command -v ffmpeg >/dev/null 2>&1; then
        mkdir -p "$OUTDIR/frames"
        ffmpeg -y -i "$OUTDIR/${VIDEO_NAME}.avi" \
            -vf fps=10 "$OUTDIR/frames/frame_%04d.png" >/dev/null 2>&1 \
            && echo "→ frames: $OUTDIR/frames"
    else
        echo "→ frames: SKIPPED (ffmpeg not found)"
    fi
  else
    echo "→ avi:    FAILED to pull (could not copy ${VIDEO_NAME}.avi from device)"
  fi
else
  echo "→ avi:    FAILED to pull (no fresh ${VIDEO_NAME}.avi recorded — 'video' likely not in active demo path)"
fi
