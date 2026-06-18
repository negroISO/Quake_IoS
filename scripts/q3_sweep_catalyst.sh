#!/usr/bin/env zsh
# Catalyst all-map render validation sweep — 27 remastered maps.
# Run from repo root or anywhere (script cds itself).
# Output: ~/Desktop/q3sim_sessions/sweep_<timestamp>_summary.txt
set -euo pipefail
cd "${0:a:h}/.."

MAPS=(
  q3dm0 q3dm1 q3dm2 q3dm3 q3tourney1 q3dm4 q3dm5 q3dm6 q3tourney2
  q3dm7 q3dm8 q3dm9 q3tourney3 q3dm10 q3dm11 q3dm12 q3tourney4
  q3dm13 q3dm14 q3dm15 q3tourney5 q3dm16 q3dm17 q3dm18 q3dm19
  q3tourney6 nv15
)

SUMMARY="$HOME/Desktop/q3sim_sessions/sweep_$(date +%Y%m%d_%H%M%S)_summary.txt"
{
  printf "%-16s %10s %24s %7s %7s %s\n" \
    "map" "asset_miss" "classicPromotedRTStages" "magenta" "fps" "verdict"
  printf "%s\n" "----------------------------------------------------------------------"
} | tee "$SUMMARY"

for map in "${MAPS[@]}"; do
  printf "%-16s " "$map"
  Q3_UPSCALE_QUALITY=medium Q3_RT_MIX=pure \
    LAUNCH_COMMAND="map $map; wait 60; quit" \
    RUN_SECS="${SWEEP_RUN_SECS:-25}" \
    ./scripts/q3dev_run_mac.sh "sweep-$map" > /dev/null 2>&1 || true

  SESSION=$(ls -dt "$HOME/Desktop/q3sim_sessions/"*"sweep-$map"* 2>/dev/null | head -1)
  if [[ -z "$SESSION" ]]; then
    printf "%10s %24s %7s %7s %s\n" "?" "?" "?" "?" "NO_SESSION"
    printf "%-16s %10s %24s %7s %7s %s\n" "$map" "?" "?" "?" "?" "NO_SESSION" >> "$SUMMARY"
    continue
  fi

  ASSET=$(grep -c '\[asset-miss\]' "$SESSION/stdout.log" 2>/dev/null || true)
  [[ -z "$ASSET" ]] && ASSET=0
  PROMO=$(grep -o 'classicPromotedRTStages=[0-9]*' "$SESSION/stdout.log" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo '?')
  MAGENTA=$(grep -c -- '-> magenta' "$SESSION/q3_diag.log" 2>/dev/null || true)
  [[ -z "$MAGENTA" ]] && MAGENTA=0
  FPS=$(grep -o 'fps=[0-9.]*' "$SESSION/stdout.log" 2>/dev/null | tail -1 | grep -o '[0-9.]*' || echo '?')

  VERDICT="OK"
  [[ "$ASSET" != "0" ]] && VERDICT="ASSET_MISS"
  [[ "$PROMO" == "?" ]] && VERDICT="NO_PROMO_METRIC"
  [[ "$PROMO" != "0" && "$PROMO" != "?" ]] && VERDICT="PROMO_ERR"
  [[ "$MAGENTA" != "0" ]] && VERDICT="MAGENTA"

  printf "%10s %24s %7s %7s %s\n" "$ASSET" "$PROMO" "$MAGENTA" "$FPS" "$VERDICT"
  printf "%-16s %10s %24s %7s %7s %s\n" "$map" "$ASSET" "$PROMO" "$MAGENTA" "$FPS" "$VERDICT" >> "$SUMMARY"
done

echo ""
echo "Summary: $SUMMARY"
