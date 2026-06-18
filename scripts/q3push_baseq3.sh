#!/usr/bin/env zsh
# q3push_baseq3.sh — sync local baseq3 sources to every reachable iPhone/iPad.
#
# Walks the same three source directories as scripts/stage_baseq3.sh,
# in the same override order, and pushes each file to
# Documents/baseq3/<relpath> on every paired+reachable device. Idempotent:
# re-running overwrites in place.
#
# Usage:
#   ./scripts/q3push_baseq3.sh                       # default Q3_RT bundle
#   ./scripts/q3push_baseq3.sh --bundle <bundle.id>  # custom bundle
#   ./scripts/q3push_baseq3.sh --device <UDID>       # one device only
#
# Examples:
#   ./scripts/q3push_baseq3.sh --bundle com.quake3ios.rt              # our Metal build
#   ./scripts/q3push_baseq3.sh --bundle com.tomkiddcog.Quake3-iOS     # Tom Kidd's port
#
# Notes:
# - "Reachable" means devicectl can talk to it RIGHT NOW. WiFi pairing
#   is enabled in Xcode → Window → Devices and Simulators → check
#   "Connect via network" once per device; thereafter the device is
#   reachable whenever it's on the same network.
# - Skips .DS_Store and *.bak. No delete is performed on-device.
# - Default bundle is com.quake3ios.rt (current Q3_RT app target).
#   Override with --bundle for any other Q3 iOS app installed on the
#   same device.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
BUNDLE="com.quake3ios.rt"

typeset -a SOURCES
SOURCES=(
  "$REPO_ROOT/baseq3"
  "$REPO_ROOT/Quake3-iOS/baseq3"
  "$REPO_ROOT/Resources/baseq3"
)
DEVICE_FILTER=""

# --bundle <id> override
while (( $# > 0 )); do
  case "$1" in
    --bundle)
      shift
      [[ -n "${1-}" ]] || { echo "ERROR: --bundle requires a bundle identifier" >&2; exit 2; }
      BUNDLE="$1"
      shift
      ;;
    --device)
      shift
      [[ -n "${1-}" ]] || { echo "ERROR: --device requires a device UDID" >&2; exit 2; }
      DEVICE_FILTER="$1"
      shift
      ;;
    -h|--help)
      sed -n '2,/^$/p' "${0:A}" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "ERROR: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

typeset -i FOUND_SOURCE=0
for src in "${SOURCES[@]}"; do
  [[ -d "$src" ]] && FOUND_SOURCE=1
done
if (( FOUND_SOURCE == 0 )); then
  echo "ERROR: no baseq3 source folders found under $REPO_ROOT" >&2
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
if [[ -n "$DEVICE_FILTER" ]]; then
  DEVICES=("${(@M)DEVICES:#$DEVICE_FILTER}")
fi

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

echo "Sources:"
for src in "${SOURCES[@]}"; do
  if [[ -d "$src" ]]; then
    echo "  ✓ $src"
  else
    echo "  - $src (missing)"
  fi
done
echo "Bundle: $BUNDLE"
[[ -n "$DEVICE_FILTER" ]] && echo "Device filter: $DEVICE_FILTER"
echo "Reachable devices: ${#DEVICES}"
for udid in "${DEVICES[@]}"; do
  printf "  • %s  [%s]\n" "${NAMES[$udid]:-<unnamed>}" "$udid"
done
echo ""

# Push every file, preserving relative path under each baseq3 source.
# Order matters and matches stage_baseq3.sh: later sources override earlier
# files with the same relative path.
typeset -i PUSHED=0
typeset -i FAILED=0

for SRC in "${SOURCES[@]}"; do
  [[ -d "$SRC" ]] || continue
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
  done < <(find "$SRC" -type f -not -name ".DS_Store" -not -name "*.bak" | sort)
done

echo ""
printf "Done. Pushed: %d   Failed: %d\n" "$PUSHED" "$FAILED"
exit $(( FAILED > 0 ? 1 : 0 ))
