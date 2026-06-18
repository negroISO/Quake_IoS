#!/bin/sh
set -eu

APP_RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST="${APP_RESOURCES}/baseq3"
STAMP="${DERIVED_FILE_DIR:-/tmp}/.stage_baseq3.stamp"

# Device-dev fast path:
#   Q3_SKIP_BUNDLED_BASEQ3=1 xcodebuild ...
# skips copying bulky pak/PBR data into the .app. The app then reads
# persistent assets from Documents/baseq3, seeded by scripts/q3push_baseq3.sh
# or scripts/q3dev_run.sh. Default stays bundled so fresh installs and Mac
# Catalyst builds keep working without extra setup.
if [ "${Q3_SKIP_BUNDLED_BASEQ3:-0}" = "1" ]; then
  echo "[stage_baseq3] Q3_SKIP_BUNDLED_BASEQ3=1; removing bundled baseq3 from app product"
  /bin/rm -rf "$DEST"
  mkdir -p "$(dirname "$STAMP")"
  touch "$STAMP"
  exit 0
fi

mkdir -p "$DEST"

copy_baseq3() {
  SRC="$1"
  LABEL="$2"
  if [ -d "$SRC" ]; then
    echo "[stage_baseq3] merging $LABEL: $SRC -> $DEST"
    /usr/bin/rsync -a --delete-excluded \
      --exclude='.DS_Store' \
      --exclude='*.bak' \
      "$SRC/" "$DEST/"
  else
    echo "[stage_baseq3] skip missing $LABEL: $SRC"
  fi
}

# Order matters: stock data first, app-local data second, custom Resources last.
# Later sources can override/add demos and pk3s without deleting earlier files.
copy_baseq3 "${SRCROOT}/baseq3" "top-level baseq3"
copy_baseq3 "${SRCROOT}/Quake3-iOS/baseq3" "app baseq3"
copy_baseq3 "${SRCROOT}/Resources/baseq3" "Resources baseq3"

# Prune known-disabled mods/paks from the staged bundle. rsync without
# --delete (which we can't safely use here because we merge multiple
# sources) leaves stale files in $DEST when their source counterparts
# get moved out. This list catches mods that shouldn't ship in the
# vanilla bundle even if a stale copy was previously staged. The pk3
# paths in _disabled-mods/ are the authoritative source archive.
for pat in 'zzz-Q3A-REMASTERED-*.pk3' 'ts_q3dm13.pk3' 'ztn3dm1.pk3' 'pak8a.pk3'; do
  for stale in "$DEST"/$pat; do
    if [ -f "$stale" ]; then
      echo "[stage_baseq3] pruning disabled pak: $stale"
      /bin/rm -f "$stale"
    fi
  done
done

PK3_COUNT=$(/usr/bin/find "$DEST" -maxdepth 1 -type f -name '*.pk3' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
DEMO_COUNT=0
if [ -d "$DEST/demos" ]; then
  DEMO_COUNT=$(/usr/bin/find "$DEST/demos" -maxdepth 1 -type f -name '*.dm_*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
fi
echo "[stage_baseq3] done: pk3=$PK3_COUNT demos=$DEMO_COUNT dest=$DEST"

# Sentinel stamp for Xcode dependency tracking.
mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
