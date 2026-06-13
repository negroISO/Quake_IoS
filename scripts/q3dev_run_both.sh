#!/usr/bin/env zsh
# Dispatch a single dev run to BOTH targets — iPad (devicectl) first,
# then Mac Catalyst — so a Codex change can be validated cross-platform
# in one command. Each leg writes its own session dir under
# ~/Desktop/q3sim_sessions/, suffixed _dev (iPad) and _mac (Catalyst).
#
# Args / env vars are passed through to both sub-runners unchanged:
#   q3dev_run_both.sh [slug]
#   DEMO=q3dm4 RUN_SECS=120 q3dev_run_both.sh q3dm4-parity
#
# Exit behavior:
#   - iPad leg failures (no device plugged in, no Debug-iphoneos build)
#     are reported but do not block the Catalyst leg. Use SKIP_IPAD=1 to
#     skip iPad entirely; SKIP_MAC=1 to skip Catalyst.

set -u

cd "${0:a:h}/.."   # repo root

SKIP_IPAD="${SKIP_IPAD:-0}"
SKIP_MAC="${SKIP_MAC:-0}"

IPAD_RC=0
MAC_RC=0

if [[ "$SKIP_IPAD" != "1" ]]; then
    echo "==============================================="
    echo "  Leg 1/2 — iPad (Debug-iphoneos via devicectl)"
    echo "==============================================="
    if scripts/q3dev_run.sh "$@"; then
        IPAD_RC=0
    else
        IPAD_RC=$?
        echo "→ iPad leg exited with $IPAD_RC (continuing to Catalyst)"
    fi
else
    echo "→ SKIP_IPAD=1, skipping iPad leg"
    IPAD_RC=-1
fi

if [[ "$SKIP_MAC" != "1" ]]; then
    echo
    echo "==============================================="
    echo "  Leg 2/2 — Mac Catalyst (Debug-maccatalyst)"
    echo "==============================================="
    if scripts/q3dev_run_mac.sh "$@"; then
        MAC_RC=0
    else
        MAC_RC=$?
        echo "→ Catalyst leg exited with $MAC_RC"
    fi
else
    echo "→ SKIP_MAC=1, skipping Catalyst leg"
    MAC_RC=-1
fi

echo
echo "==============================================="
echo "  Dual-target summary"
echo "==============================================="
echo "  iPad     exit: $IPAD_RC"
echo "  Catalyst exit: $MAC_RC"
echo

# Surface the most recent session dir from each leg for downstream
# diff tooling. Sessions are tagged _dev / _mac so a glob is sufficient.
LATEST_DEV=$(ls -1dt "$HOME"/Desktop/q3sim_sessions/*_dev 2>/dev/null | head -1)
LATEST_MAC=$(ls -1dt "$HOME"/Desktop/q3sim_sessions/*_mac 2>/dev/null | head -1)
[[ -n "$LATEST_DEV" ]] && echo "  iPad session:     $LATEST_DEV"
[[ -n "$LATEST_MAC" ]] && echo "  Catalyst session: $LATEST_MAC"

# Non-zero only when BOTH legs failed; partial-success exits 0 so a
# missing iPad doesn't kill the dual-run.
if [[ "$IPAD_RC" != "0" && "$MAC_RC" != "0" && "$IPAD_RC" != "-1" && "$MAC_RC" != "-1" ]]; then
    exit 1
fi
exit 0
