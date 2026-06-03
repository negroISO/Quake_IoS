#!/usr/bin/env bash
# iphone_q3_quality_avi_all.sh — capture the same Q3 demo at all four
# MetalFX quality levels (Native, High, Medium, Low), back-to-back.
# Each level runs as a fresh app launch with the corresponding env var.
#
# Usage
#   scripts/iphone_q3_quality_avi_all.sh [duration_s] [demo_name]
#     duration:  default 20 (each capture)
#     demo_name: default "four" (Q3 default — Camping Grounds q3dm6)
#
# Output
#   /tmp/q3_avi/q3_native_<HHMMSS>.{avi,mp4}
#   /tmp/q3_avi/q3_high_<HHMMSS>.{avi,mp4}
#   /tmp/q3_avi/q3_medium_<HHMMSS>.{avi,mp4}
#   /tmp/q3_avi/q3_low_<HHMMSS>.{avi,mp4}
#
# Total runtime ≈ 4 × (10 init + duration + 2) + pull time. With
# duration=20 that's ~3 minutes wall-clock, plus AVI pull (~30 s per
# native-res file = ~2 min). Allow ~6 minutes for the full sweep.

set -euo pipefail

DURATION="${1:-20}"
DEMO="${2:-four}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SINGLE="$SCRIPT_DIR/iphone_q3_quality_avi.sh"

if [[ ! -x "$SINGLE" ]]; then
  chmod +x "$SINGLE" 2>/dev/null || true
fi

OUT_DIR="${OUT_DIR:-/tmp/q3_avi}"
mkdir -p "$OUT_DIR"

echo "=================================================================="
echo " Q3 MetalFX quality sweep — capturing all 4 levels"
echo "   demo:      $DEMO"
echo "   duration:  ${DURATION}s each"
echo "   output:    $OUT_DIR"
echo "=================================================================="

for q in native high medium low; do
  echo ""
  echo ">>> [$q] starting capture..."
  if OUT_DIR="$OUT_DIR" "$SINGLE" "$q" "$DURATION" "$DEMO"; then
    echo ">>> [$q] OK"
  else
    echo ">>> [$q] FAILED — continuing with next level"
  fi
  # Small gap so the device can settle before the next launch.
  sleep 3
done

echo ""
echo "=================================================================="
echo " Done. Files in $OUT_DIR:"
echo "=================================================================="
ls -lhS "$OUT_DIR" | grep -E '\.(avi|mp4)$' || echo "  (no captures found — check individual logs)"
