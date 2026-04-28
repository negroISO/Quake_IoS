#!/usr/bin/env bash

# Usage:
# ./q3_shader_diff_prompt.sh <shader_name>

SHADER="$1"

echo "=== SHADER PARITY CHECK ==="
echo "Shader: $SHADER"
echo ""

echo "Provide analysis for:"
echo "1. Vulkan (Kenny Edition) shader behavior"
echo "2. ioq3 original behavior"
echo "3. Metal implementation"

echo ""
echo "Return ONLY:"
echo "- mismatch category (blend/tcMod/tcGen/lighting)"
echo "- exact difference"
echo "- minimal fix suggestion"