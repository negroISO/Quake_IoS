#!/usr/bin/env bash
# Pulls q3_diag.log from the connected iPhone, archives the file under
# docs/q3-logs/ with a timestamp, then wipes the device-side log so it
# does not grow without bound.
#
# Usage:
#   scripts/pull_q3_diag.sh                       # default device "Yd-Mubarak MajMaj"
#   scripts/pull_q3_diag.sh "Oled"                # iPad Pro 13"
#   scripts/pull_q3_diag.sh "" no-wipe             # pull only, leave device log intact
#
# What ends up in docs/q3-logs/:
#   q3_diag-YYYYMMDD-HHMMSS.log     # full session log, never modified after archive
#   INDEX.md                         # appended one line per archive — quick browse
#
# How to read prior runs:
#   cat docs/q3-logs/INDEX.md                # list everything
#   less docs/q3-logs/q3_diag-<ts>.log        # specific session
#   grep -l 'thing-I-care-about' docs/q3-logs/q3_diag-*.log   # search across sessions

set -euo pipefail

DEVICE="${1:-Yd-Mubarak MajMaj}"
WIPE_MODE="${2:-wipe}"   # second arg "no-wipe" to skip the device-side truncate
BUNDLE_ID="com.quake3ios.app"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/docs/q3-logs"
mkdir -p "$DEST_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
DEST="$DEST_DIR/q3_diag-${TS}.log"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[pull] device=$DEVICE bundle=$BUNDLE_ID → $DEST"

# 1) pull
if ! xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/q3_diag.log \
        --destination "$DEST" 2>&1 | tail -8 ; then
    echo "[pull] devicectl copy from FAILED — is the device connected + paired?" >&2
    exit 1
fi

if [[ ! -s "$DEST" ]] ; then
    echo "[pull] pulled file is empty (size 0) — device log already clean or app not run since last pull"
    rm -f "$DEST"
    exit 0
fi

SIZE=$(stat -f %z "$DEST" 2>/dev/null || stat -c %s "$DEST")
LINES=$(wc -l < "$DEST" | tr -d ' ')
echo "[pull] archived: $DEST ($SIZE bytes, $LINES lines)"

# 2) wipe device-side (push an empty file back into the same path)
if [[ "$WIPE_MODE" != "no-wipe" ]] ; then
    EMPTY="$TMP_DIR/q3_diag.log"
    : > "$EMPTY"
    echo "[wipe] truncating device-side q3_diag.log"
    if ! xcrun devicectl device copy to \
            --device "$DEVICE" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "$EMPTY" \
            --destination Documents/q3_diag.log 2>&1 | tail -5 ; then
        echo "[wipe] failed — archive is still safe, device log untouched" >&2
        exit 1
    fi
    echo "[wipe] done"
else
    echo "[wipe] skipped (no-wipe mode)"
fi

# 3) index
INDEX="$DEST_DIR/INDEX.md"
if [[ ! -f "$INDEX" ]] ; then
    {
        echo "# Q3-iOS diagnostic log archive"
        echo ""
        echo "Each entry below is one captured session (one full launch-to-quit run)."
        echo "Pulled via \`scripts/pull_q3_diag.sh\`. Device-side log is wiped after"
        echo "each successful pull so the in-app file never grows past one run."
        echo ""
        echo "| Pulled at | File | Lines | Notes |"
        echo "|---|---|---:|---|"
    } > "$INDEX"
fi
PRETTY_TS="$(date -j -f '%Y%m%d-%H%M%S' "$TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$TS")"
printf '| %s | [q3_diag-%s.log](./q3_diag-%s.log) | %s |  |\n' \
    "$PRETTY_TS" "$TS" "$TS" "$LINES" >> "$INDEX"

echo "[done] $DEST_DIR/INDEX.md updated"
