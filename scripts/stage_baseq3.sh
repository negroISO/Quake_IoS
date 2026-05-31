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

PK3_COUNT=$(/usr/bin/find "$DEST" -maxdepth 1 -type f -name '*.pk3' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
DEMO_COUNT=0
if [ -d "$DEST/demos" ]; then
  DEMO_COUNT=$(/usr/bin/find "$DEST/demos" -maxdepth 1 -type f -name '*.dm_*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
fi
echo "[stage_baseq3] done: pk3=$PK3_COUNT demos=$DEMO_COUNT dest=$DEST"
