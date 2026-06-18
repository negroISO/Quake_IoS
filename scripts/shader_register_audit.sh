#!/bin/bash
# shader_register_audit.sh - extract per-function AIR stats from MetalView.swift's
# inlined MSL string. Used as a register-pressure proxy for before/after diffs.
#
# Limitation: Apple GPU native register count is not exposed via CLI tools — only
# through Xcode Shader Profiler at runtime. AIR (LLVM IR) instruction count and
# SSA vreg count are a strong proxy: fewer live values → fewer GPU registers used.
#
# Usage:
#   ./shader_register_audit.sh                 # snapshot the current tree
#   ./shader_register_audit.sh --label patched # tag the output with a label
set -euo pipefail
REPO="/Users/targus/Documents/Quake_IoS_Phase9_Fork"
DUMP="$REPO/scripts/shader_dump"
LABEL="${1:-current}"
[ "$LABEL" = "--label" ] && LABEL="$2"

mkdir -p "$DUMP"
cd "$DUMP"

echo "=== shader_register_audit [$LABEL] ==="
echo "Extracting MSL from MetalView.swift lines 1245-3183..."
sed -n '1245,3183p' "$REPO/Quake3-iOS/MetalView.swift" > world.metal

echo "Compiling world.metal -> world.metallib..."
xcrun metal -target air64-apple-ios18.0 -O2 -ffast-math world.metal -o world.metallib 2>&1 | grep -v "incompatible-sysroot\|unused variable 'fallbackSampler'" | grep -v "^[[:space:]]*\^\$\|^[[:space:]]*constexpr sampler\|^[[:space:]]*\^[~]*$" || true

echo "Dumping AIR..."
xcrun metal-objdump --disassemble world.metallib 2>/dev/null > world.air.ll

# Per-function stats. Walk the IR line by line, count between matching `define`
# and `^}` braces. Track: total lines, SSA vreg count (%N), instruction count
# (non-blank, non-label, non-comment), function calls (`call`), branches (`br`,
# `phi`), loads/stores, fmul, fadd.
python3 << 'PYEOF'
import re

with open('world.air.ll') as f:
    lines = f.readlines()

# Find function ranges
funcs = []
cur_name = None
cur_start = None
depth = 0
for i, line in enumerate(lines):
    m = re.match(r'^define\s.*@(\w+)\s*\(', line)
    if m and cur_name is None:
        cur_name = m.group(1)
        cur_start = i
        depth = line.count('{') - line.count('}')
        continue
    if cur_name:
        depth += line.count('{') - line.count('}')
        if depth == 0:
            funcs.append((cur_name, cur_start, i))
            cur_name = None

print(f"Found {len(funcs)} functions")
print()
print(f"{'Function':<28} {'Lines':>7} {'Vregs':>7} {'Insns':>7} {'Calls':>7} {'BRs':>5} {'Phis':>5} {'Loads':>6} {'Stores':>7} {'FMuls':>6} {'FAdds':>6}")
print("-" * 110)

stats = {}
for name, start, end in funcs:
    body = lines[start:end+1]
    # Largest SSA vreg id (proxy for live-range count)
    vreg_max = 0
    insns = 0
    calls = 0
    brs = 0
    phis = 0
    loads = 0
    stores = 0
    fmuls = 0
    fadds = 0
    for ln in body:
        s = ln.strip()
        if not s or s.startswith(';') or s.endswith(':'):
            continue
        if s.startswith('define') or s == '}':
            continue
        # Find largest vreg in this line
        for m in re.finditer(r'%(\d+)\b', ln):
            vreg_max = max(vreg_max, int(m.group(1)))
        # Instruction patterns
        if re.match(r'^\s*%\d+\s*=', ln) or re.match(r'^\s*(store|call|br|ret|switch|unreachable|tail)', ln):
            insns += 1
        if 'call ' in ln or 'tail call' in ln:
            calls += 1
        if re.match(r'^\s*br\s', ln):
            brs += 1
        if 'phi ' in ln:
            phis += 1
        if re.search(r'\bload\b', ln):
            loads += 1
        if re.search(r'^\s*store\b', ln):
            stores += 1
        if re.search(r'\bfmul\b', ln):
            fmuls += 1
        if re.search(r'\bfadd\b', ln):
            fadds += 1
    stats[name] = {
        'lines': end - start + 1,
        'vreg_max': vreg_max,
        'insns': insns,
        'calls': calls,
        'brs': brs,
        'phis': phis,
        'loads': loads,
        'stores': stores,
        'fmuls': fmuls,
        'fadds': fadds,
    }
    print(f"{name:<28} {stats[name]['lines']:>7} {vreg_max:>7} {insns:>7} {calls:>7} {brs:>5} {phis:>5} {loads:>6} {stores:>7} {fmuls:>6} {fadds:>6}")

# Save machine-readable form
import json, sys, os
label = os.environ.get('LABEL', 'current')
out = f"world_stats_{label}.json"
with open(out, 'w') as f:
    json.dump(stats, f, indent=2)
print(f"\nSaved {out}")
PYEOF

echo "=== done [$LABEL] ==="
