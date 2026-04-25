#!/usr/bin/env bash
# q3anchor_gemma.sh — run the ralph_loop.txt §9.4 anchor-validation
# prompt against one or all anchor folders in ~/Documents/Quake_IoS/
# debug_pairs/. Gemma returns the strict format:
#
#   ANCHOR: <folder_name>
#   MATCH: PASS | FAIL
#   DIFF_TYPE: BLEND | LIGHTING | ENTITY | WORLD | PRECISION | UNKNOWN
#   OBSERVATIONS: ...
#   ROOT_CAUSE: ...
#   CONFIDENCE: HIGH | MEDIUM | LOW
#
# Usage:
#   scripts/q3anchor_gemma.sh                # all anchors
#   scripts/q3anchor_gemma.sh four_frame_119 # single anchor
#
# Results land at ~/Documents/Quake_IoS/debug_pairs/<anchor>/result.txt

set -euo pipefail

REPO=/Users/targus/Documents/Quake_IoS
DEBUG_PAIRS="$REPO/debug_pairs"
URL="${LMSTUDIO_URL:-http://192.168.0.77:1234}"
MODEL="${LMSTUDIO_MODEL:-google/gemma-4-31b}"

SYSTEM='You are a strict Quake 3 rendering-parity auditor. You receive two images: the first is our custom Metal renderer output, the second is the ground-truth reference. You compare ONLY these two images. Ignore compression artifacts, minor brightness variance, and resolution differences. Focus on structural rendering differences.

Output MUST match this exact format and nothing else:
ANCHOR: <folder_name>
MATCH: PASS | FAIL
DIFF_TYPE: BLEND | LIGHTING | ENTITY | WORLD | PRECISION | UNKNOWN
OBSERVATIONS:
- <bullet>
- <bullet>
ROOT_CAUSE: <single Q3 concept: blendFunc | rgbGen | lightingDiffuse | alphaFunc | tcMod | lightmap combine>
CONFIDENCE: HIGH | MEDIUM | LOW

Decision logic:
- decals missing -> BLEND
- scene tinted/glowing/yellow -> BLEND
- player lighting differs from world -> ENTITY
- floor/walls show banding or color shift -> PRECISION
- explosions too strong or bleed -> BLEND
- geometry correct but shading off -> LIGHTING

HARD RULES: NO guessing. NO multiple root causes. NO "maybe". NO engine redesign suggestions. NO Metal-specific speculation. ONLY upstream Quake 3 behavior allowed.'

run_anchor() {
  local anchor="$1"
  local dir="$DEBUG_PAIRS/$anchor"
  local out_png="$dir/out.png"
  local ref_png="$dir/ref.png"
  local info="$dir/info.txt"
  local result="$dir/result.txt"

  if [[ ! -f "$out_png" || ! -f "$ref_png" ]]; then
    echo "SKIP: $anchor (missing ref.png or out.png)"
    return 1
  fi

  local anchor_type
  anchor_type=$(grep -m1 '^type=' "$info" 2>/dev/null | cut -d= -f2- || echo "unknown")

  local user_prompt
  user_prompt=$(printf '%s' "ANCHOR: $anchor
EXPECTED_TYPE: $anchor_type
Image #1 = custom Metal renderer output (out.png)
Image #2 = ground-truth reference (ref.png)
Return ONLY the strict format specified in the system prompt.")

  local out_b64 ref_b64
  out_b64=$(base64 -i "$out_png")
  ref_b64=$(base64 -i "$ref_png")

  local tmp
  tmp=$(mktemp /tmp/anchor.XXXX.json)
  {
    printf '{"model":"%s","max_tokens":500,"temperature":0.0,"messages":[' "$MODEL"
    printf '{"role":"system","content":%s},' "$(printf '%s' "$SYSTEM" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
    printf '{"role":"user","content":['
    printf '{"type":"text","text":%s},' "$(printf '%s' "$user_prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
    printf '{"type":"image_url","image_url":{"url":"data:image/png;base64,%s"}},' "$out_b64"
    printf '{"type":"image_url","image_url":{"url":"data:image/png;base64,%s"}}' "$ref_b64"
    printf ']}]}'
  } > "$tmp"

  local body
  body=$(curl -sS -m 240 -H 'Content-Type: application/json' -X POST "$URL/v1/chat/completions" --data @"$tmp")
  rm -f "$tmp"

  local content
  content=$(printf '%s' "$body" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print(d["choices"][0]["message"]["content"])
except Exception as e:
  print(f"ERROR: {e}", file=sys.stderr)
  sys.exit(1)
')
  echo "=== $anchor ==="
  echo "$content"
  echo ""
  {
    echo "# anchor=$anchor type=$anchor_type"
    echo "$content"
  } > "$result"
}

if [[ $# -ge 1 ]]; then
  for a in "$@"; do run_anchor "$a"; done
else
  for dir in "$DEBUG_PAIRS"/four_frame_*; do
    [[ -d "$dir" ]] && run_anchor "$(basename "$dir")"
  done
fi

# Aggregate priority order based on CRITICAL anchor result.txt verdicts.
echo ""
echo "=== AGGREGATED ==="
python3 - "$DEBUG_PAIRS" <<'PY'
import os, sys, re
root = sys.argv[1]
criticals = ["four_frame_227", "four_frame_141", "four_frame_235"]
fails_by_type = {}
all_results = []
for anchor in sorted(os.listdir(root)):
    rp = os.path.join(root, anchor, "result.txt")
    if not os.path.isfile(rp): continue
    txt = open(rp).read()
    m_match = re.search(r"MATCH:\s*(PASS|FAIL)", txt)
    m_type  = re.search(r"DIFF_TYPE:\s*(\w+)", txt)
    m_root  = re.search(r"ROOT_CAUSE:\s*([^\n]+)", txt)
    m_conf  = re.search(r"CONFIDENCE:\s*(\w+)", txt)
    verdict = m_match.group(1) if m_match else "?"
    diff_type = m_type.group(1) if m_type else "UNKNOWN"
    root_cause = (m_root.group(1).strip() if m_root else "")
    conf = m_conf.group(1) if m_conf else "?"
    all_results.append((anchor, verdict, diff_type, root_cause, conf))
    if verdict == "FAIL":
        fails_by_type.setdefault(diff_type, []).append(anchor)

print("ANCHOR                       VERDICT  TYPE         ROOT_CAUSE                                CONFIDENCE")
for a, v, t, rc, c in all_results:
    print(f"{a:<28} {v:<8} {t:<12} {rc[:40]:<40} {c}")

print("\nCRITICAL_STATUS:")
for a in criticals:
    match = next((r for r in all_results if r[0] == a), None)
    print(f"  {a}: {match[1] if match else 'MISSING'}")

# PRIORITY_ORDER by # of FAILs per DIFF_TYPE
sorted_types = sorted(fails_by_type.items(), key=lambda kv: -len(kv[1]))
print("\nPRIORITY_ORDER:")
for i, (typ, anchors) in enumerate(sorted_types[:3], 1):
    print(f"  {i}. {typ} ({len(anchors)} anchor(s): {', '.join(anchors)})")

dom = sorted_types[0][0] if sorted_types else "NONE"
print(f"\nDOMINANT_FAILURE: {dom}")
PY
