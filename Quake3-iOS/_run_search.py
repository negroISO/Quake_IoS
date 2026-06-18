#!/usr/bin/env python3
import subprocess, sys

result = subprocess.run(
    ["python3", "/Users/targus/Documents/Quake_IoS_Phase9_Fork/Quake3-iOS/_search_patterns.py"],
    capture_output=True, text=True, timeout=30
)
print(result.stdout)
if result.stderr:
    print("STDERR:", result.stderr[:2000], file=sys.stderr)
print(f"Exit code: {result.returnout}", file=sys.stderr)
