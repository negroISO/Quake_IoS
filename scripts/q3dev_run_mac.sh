#!/usr/bin/env zsh
# Run the Catalyst Q3_RT.app on this Mac, capture stdout, and pull the
# qconsole.log + recorded AVI out of the Catalyst container at the end.
# Layout matches q3dev_run.sh so q3vision_diff / q3_mae_q3dm4 / etc.
# treat iPad and Catalyst runs interchangeably.
#
# Sibling to q3dev_run.sh; same env-var override surface:
#   q3dev_run_mac.sh [slug]
#   DEMO=q3dm4   q3dev_run_mac.sh q3dm4-mac
#   RUN_SECS=120 q3dev_run_mac.sh
#   VIDEO_NAME=q3dm4 q3dev_run_mac.sh q3dm4-mac
#
# Assumes: Debug-maccatalyst build of Q3_RT.app already exists in
# DerivedData. Build it via "Mac (Mac Catalyst)" destination in Xcode
# or via `xcodebuild -scheme Quake3-iOS -destination 'platform=macOS,variant=Mac Catalyst'`.

set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.quake3ios.rt}"
RUN_SECS="${RUN_SECS:-90}"
DEMO="${DEMO:-four}"
VIDEO_NAME="${VIDEO_NAME:-$DEMO}"
LAUNCH_COMMAND="${LAUNCH_COMMAND:-demo $DEMO; wait 50; video $VIDEO_NAME; wait 1500; stopvideo; quit}"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData}"

# Render-quality defaults — Codex's prior iteration ran at low (480p
# upscale-source) which makes captures look pixelated even though
# the drawable is native 3456×2234. medium (0.5×, ~1728×1117) keeps
# perf reasonable AND gives real source detail. Override per-invocation
# via env: Q3_UPSCALE_QUALITY=native (no upscale, ~14fps ceiling),
# high (0.75×), medium (0.5×), low (480p).
# r_rt_mix=pure (RT on) is the right default — this is the Q3RT
# renderer, not the raster baseline.
export Q3_UPSCALE_QUALITY="${Q3_UPSCALE_QUALITY:-medium}"
export Q3_RT_MIX="${Q3_RT_MIX:-pure}"

# Pick newest Debug-maccatalyst Q3_RT.app, filtered by CFBundleIdentifier.
APP=$(/usr/bin/find "$DERIVED" -maxdepth 6 -type d \( -name "Q3_RT.app" -o -name "Quake3-iOS.app" \) \
        -path "*Debug-maccatalyst*" -not -path "*Index.noindex*" 2>/dev/null \
        | while read -r p; do
            plist="$p/Contents/Info.plist"
            if [[ -f "$plist" ]]; then
                bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)
                if [[ "$bid" == "$BUNDLE_ID" ]]; then
                    echo "$(/usr/bin/stat -f '%m' "$p") $p"
                fi
            fi
          done \
        | sort -rn | head -1 | cut -d' ' -f2-)
[[ -z "$APP" ]] && { echo "ERR: Debug-maccatalyst .app for $BUNDLE_ID not found in $DERIVED — build via Mac Catalyst destination first" >&2; exit 1; }

# Catalyst sandbox container for this bundle. Direct Catalyst launches may
# use a UUID-named container (with Saved Application State ending in
# <bundle>.rt~iosmac) rather than ~/Library/Containers/<bundle-id>. Resolve
# the newest real container so autoexec/log pulls target the same sandbox the
# app actually uses.
resolve_catalyst_container() {
    /usr/bin/python3 - "$BUNDLE_ID" <<'PY'
import os, sys
bundle = sys.argv[1]
root = os.path.expanduser("~/Library/Containers")
candidates = []
if os.path.isdir(root):
    for name in os.listdir(root):
        data = os.path.join(root, name, "Data")
        if not os.path.isdir(data):
            continue
        pref = os.path.join(data, "Library", "Preferences", f"{bundle}.plist")
        state = os.path.join(data, "Library", "Saved Application State", f"{bundle}~iosmac.savedState")
        if os.path.exists(pref) or os.path.exists(state):
            mtimes = [os.path.getmtime(data)]
            if os.path.exists(pref): mtimes.append(os.path.getmtime(pref))
            if os.path.exists(state): mtimes.append(os.path.getmtime(state))
            candidates.append((max(mtimes), data))
if candidates:
    print(sorted(candidates, reverse=True)[0][1])
else:
    print(os.path.join(root, bundle, "Data"))
PY
}

CONTAINER="$(resolve_catalyst_container)"
DOCS="$CONTAINER/Documents"
BASEQ3="$DOCS/baseq3"

cd "${0:a:h}/.."                                # repo root
SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s | tr '[:upper:]' '[:lower:]')
SLUG="${1:-$(echo "$SUBJECT" \
                | sed -E 's/^[a-z]+(\([^)]+\))?: *//' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
                | cut -c1-40)}"
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Desktop/q3sim_sessions/${STAMP}__${SHA}_${SLUG}_mac"
mkdir -p "$OUTDIR"
echo "→ app:     $APP"
echo "→ logs:    $OUTDIR"
echo "→ runtime: ${RUN_SECS}s"
echo "→ command: $LAUNCH_COMMAND"

# Push autoexec.cfg into the Catalyst sandbox so logfile=2/developer=1
# take effect for this run. Catalyst's container is just a regular Mac
# directory — cp, not devicectl.
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
mkdir -p "$BASEQ3"
cp -f "$AUTOEXEC" "$BASEQ3/autoexec.cfg" \
    && echo "→ cfg:     pushed autoexec.cfg → $BASEQ3/autoexec.cfg"
[[ -n "$TMP_AUTOEXEC" ]] && rm -f "$TMP_AUTOEXEC"

# Keep each Catalyst session self-contained. q3_diag.log lives outside
# baseq3 and otherwise accumulates across maps/runs, which makes grep-based
# acceptance checks report stale failures.
rm -f "$DOCS/q3_diag.log" "$BASEQ3/qconsole.log"

# Mirror demos into the Catalyst sandbox (.dm_68 + .dm_73) so playback
# commands resolve identically to the device path.
DEMO_DIR="Resources/baseq3/demos"
if [[ -d "$DEMO_DIR" ]]; then
    mkdir -p "$BASEQ3/demos"
    for d in "$DEMO_DIR"/*.dm_68(N) "$DEMO_DIR"/*.dm_73(N); do
        [[ -f "$d" ]] || continue
        cp -f "$d" "$BASEQ3/demos/${d:t}"
    done
    echo "→ demos:   mirrored into $BASEQ3/demos"
fi

# Kill any stale Q3_RT instance so we get a clean run.
pkill -TERM -x Q3_RT 2>/dev/null || true
sleep 1

# Launch the binary directly (not `open`) so we capture stdout in the
# session dir, exactly like devicectl --console does on iPad.
BIN="$APP/Contents/MacOS/Q3_RT"
[[ -x "$BIN" ]] || { echo "ERR: launch binary missing at $BIN" >&2; exit 1; }

Q3_LAUNCH_COMMAND="$LAUNCH_COMMAND" \
    "$BIN" > "$OUTDIR/stdout.log" 2>&1 &
LAUNCH_PID=$!
echo "→ launched (pid $LAUNCH_PID)"

trap "kill -TERM $LAUNCH_PID 2>/dev/null || true; pkill -TERM -x Q3_RT 2>/dev/null || true" EXIT INT TERM

sleep "$RUN_SECS"
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
pkill -TERM -x Q3_RT 2>/dev/null || true
sleep 2

LINES=$(wc -l < "$OUTDIR/stdout.log")
echo "→ stdout:  $LINES lines"

# Refresh container after launch in case this was the first run and Catalyst
# created the UUID sandbox only after process start.
CONTAINER="$(resolve_catalyst_container)"
DOCS="$CONTAINER/Documents"
BASEQ3="$DOCS/baseq3"
echo "→ container: $CONTAINER"

# Pull qconsole.log — same intent as the iPad runner.
QCONS="$BASEQ3/qconsole.log"
if [[ -f "$QCONS" ]]; then
    cp -f "$QCONS" "$OUTDIR/qconsole.log"
    QC_LINES=$(wc -l < "$OUTDIR/qconsole.log" 2>/dev/null || echo 0)
    echo "→ qlog:    $OUTDIR/qconsole.log ($QC_LINES lines)"
else
    echo "→ qlog:    FAILED to find $QCONS (autoexec.cfg pushed? logfile cvar live?)"
fi

# Pull q3_diag.log if present. On iPad we grab this through devicectl;
# on Catalyst it lands in Documents/ directly.
DIAG="$DOCS/q3_diag.log"
if [[ -f "$DIAG" ]]; then
    cp -f "$DIAG" "$OUTDIR/q3_diag.log"
    DIAG_LINES=$(wc -l < "$OUTDIR/q3_diag.log" 2>/dev/null || echo 0)
    echo "→ diag:    $OUTDIR/q3_diag.log ($DIAG_LINES lines)"
fi

# Pull the recorded AVI + slice frames at 10fps (parity with iPad path).
AVI="$BASEQ3/videos/${VIDEO_NAME}.avi"
if [[ -f "$AVI" ]]; then
    cp -f "$AVI" "$OUTDIR/${VIDEO_NAME}.avi"
    AVI_SIZE=$(/usr/bin/stat -f '%z' "$OUTDIR/${VIDEO_NAME}.avi")
    AVI_MB=$((AVI_SIZE / 1024 / 1024))
    echo "→ avi:     $OUTDIR/${VIDEO_NAME}.avi (${AVI_MB} MB)"
    if command -v ffmpeg >/dev/null 2>&1; then
        mkdir -p "$OUTDIR/frames"
        ffmpeg -y -i "$OUTDIR/${VIDEO_NAME}.avi" \
            -vf fps=10 "$OUTDIR/frames/frame_%04d.png" >/dev/null 2>&1 \
            && echo "→ frames:  $OUTDIR/frames"
    else
        echo "→ frames:  SKIPPED (ffmpeg not found)"
    fi
else
    echo "→ avi:     FAILED to find $AVI (no recording — video cbuf disabled?)"
fi
