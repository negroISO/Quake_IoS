#!/usr/bin/env zsh
# q3push_baseq3.sh — sync Resources/baseq3/ to every reachable iPhone/iPad.
#
# Walks the local Resources/baseq3/ tree and pushes each file to
# Documents/baseq3/<relpath> on every paired+reachable device (USB
# "connected" or WiFi "available (paired)" per devicectl). Sub-folders
# are preserved (so demos/foo.dm_73 lands at Documents/baseq3/demos/
# foo.dm_73). Idempotent: re-running overwrites in place — drop a new
# pk3 / .dm_* into Resources/baseq3/, run this script, both devices
# get it.
#
# Usage:
#   ./scripts/q3push_baseq3.sh
#
# Notes:
# - "Reachable" means devicectl can talk to it RIGHT NOW. WiFi pairing
#   is enabled in Xcode → Window → Devices and Simulators → check
#   "Connect via network" once per device; thereafter the device is
#   reachable whenever it's on the same network.
# - Skips .DS_Store. No other filtering — every other file under
#   Resources/baseq3/ is pushed.
# - Bundle ID is hardcoded to com.quake3ios.app (the app's
#   PRODUCT_BUNDLE_IDENTIFIER per project.yml).

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SRC="$REPO_ROOT/Resources/baseq3"
BUNDLE="com.quake3ios.app"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source folder not found: $SRC" >&2
  exit 1
fi

# Find paired+reachable iPhone/iPad UDIDs.
# devicectl row layout (fixed-width-ish):
#   Name  DNS  UDID  State  ProductType
# State values we accept: "connected" (USB), "available (paired)" (WiFi).
# State we reject: "unavailable".
typeset -a DEVICES
DEVICES=("${(@f)$(
  xcrun devicectl list devices 2>/dev/null \
  | grep -vE 'unavailable' \
  | grep -E '\((iPhone|iPad)' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
  | sort -u
)}")

# Filter out empty entries (zsh quirks with grep producing nothing).
DEVICES=("${(@)DEVICES:#}")

if (( ${#DEVICES} == 0 )); then
  cat >&2 <<EOF
No reachable iPhone/iPad devices found.
- Plug in a device via USB, OR
- Pair over WiFi: Xcode → Window → Devices and Simulators
  → select device → check "Connect via network".
EOF
  exit 1
fi

# Map UDIDs to friendly names for the log.
typeset -A NAMES
while IFS= read -r line; do
  [[ "$line" == *"unavailable"* ]] && continue
  if [[ "$line" =~ '([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})' ]]; then
    udid="${match[1]}"
    name="${line%% *}"
    [[ -n "$name" ]] && NAMES[$udid]="$name"
  fi
done < <(xcrun devicectl list devices 2>/dev/null)

echo "Source: $SRC"
echo "Reachable devices: ${#DEVICES}"
for udid in "${DEVICES[@]}"; do
  printf "  • %s  [%s]\n" "${NAMES[$udid]:-<unnamed>}" "$udid"
done
echo ""

# Push every file, preserving relative path under Resources/baseq3/.
typeset -i PUSHED=0
typeset -i FAILED=0

while IFS= read -r FILE; do
  REL="${FILE#$SRC/}"
  DEST="Documents/baseq3/$REL"
  for udid in "${DEVICES[@]}"; do
    NAME="${NAMES[$udid]:-${udid:0:8}…}"
    if xcrun devicectl device copy to \
        --device "$udid" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" \
        --source "$FILE" \
        --destination "$DEST" >/dev/null 2>&1; then
      printf "  ✓ %-55s → %s\n" "$REL" "$NAME"
      PUSHED=$((PUSHED + 1))
    else
      printf "  ✗ %-55s → %s (FAILED)\n" "$REL" "$NAME"
      FAILED=$((FAILED + 1))
    fi
  done
done < <(find "$SRC" -type f -not -name ".DS_Store" | sort)

echo ""
printf "Done. Pushed: %d   Failed: %d\n" "$PUSHED" "$FAILED"
exit $(( FAILED > 0 ? 1 : 0 ))
