#!/bin/sh
set -eu

APP_RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST="${APP_RESOURCES}/baseq3"
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
for pat in 'zzz-Q3A-REMASTERED-*.pk3'; do
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
