#!/usr/bin/env bash
# Send one or more PNG frames to a local vision-capable LM Studio model
# and print its text response. Intended for offloading frame-by-frame
# visual QA of Quake 3 iOS simulator captures.
#
# Usage:
#   gemma_review.sh <frame.png> [<frame2.png> ...]               # review, using QUAKE_PROMPT
#   gemma_review.sh --prompt "custom question" <frame.png> ...
#   gemma_review.sh --system "custom system" --prompt "..." <frames>
#
# Env:
#   LMSTUDIO_URL    default http://192.168.0.77:1234
#   LMSTUDIO_MODEL  default google/gemma-4-31b
#   QUAKE_PROMPT    default question ("describe HUD head state etc.")

set -euo pipefail

URL="${LMSTUDIO_URL:-http://192.168.0.77:1234}"
MODEL="${LMSTUDIO_MODEL:-google/gemma-4-31b}"

SYSTEM_DEFAULT='You are a vision-based QA bot reviewing Quake 3 Arena iOS simulator screenshots rendered by a custom Metal renderer. Answer strictly from what you see, no speculation. Keep responses to short bullets. Every response MUST end with a single line: "VERDICT: <home-screen|menu|loading|gameplay|scoreboard|other>".'

PROMPT_DEFAULT='For this frame, report:
- Is the frame showing the 3D game world (walls, floor, lamps), a menu, a loading screen, the iOS home screen, or a scoreboard?
- Is there a HUD portrait slot at the bottom-right? If yes, is a 3D player head model rendered inside it or is the slot empty/blank?
- Is a weapon viewmodel visible? If yes, does it have texture or is it flat white?
- Any rendering glitches (all-black areas, missing textures, geometry holes)?'

system_msg="$SYSTEM_DEFAULT"
prompt_msg="$PROMPT_DEFAULT"

files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) prompt_msg="$2"; shift 2 ;;
    --system) system_msg="$2"; shift 2 ;;
    --model)  MODEL="$2";      shift 2 ;;
    --url)    URL="$2";         shift 2 ;;
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        files+=("$1");   shift   ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "usage: $0 [--prompt ...] [--system ...] <frame.png> ..." >&2
  exit 2
fi

# Build JSON request using python (to safely encode base64 + escape prompts).
python3 - "$URL" "$MODEL" "$system_msg" "$prompt_msg" "${files[@]}" <<'PY'
import base64, json, sys, urllib.request

url, model, system_msg, prompt_msg, *paths = sys.argv[1:]

user_content = [{"type": "text", "text": prompt_msg}]
for p in paths:
    with open(p, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    user_content.append({
        "type": "image_url",
        "image_url": {"url": f"data:image/png;base64,{b64}"}
    })

body = {
    "model": model,
    "messages": [
        {"role": "system", "content": system_msg},
        {"role": "user",   "content": user_content},
    ],
    "max_tokens": 800,
    "temperature": 0.1,
}

req = urllib.request.Request(
    url.rstrip("/") + "/v1/chat/completions",
    data=json.dumps(body).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=180) as resp:
    data = json.loads(resp.read().decode("utf-8"))

for p in paths:
    print(f"=== {p} ===", file=sys.stderr)
print(data["choices"][0]["message"]["content"])
PY
