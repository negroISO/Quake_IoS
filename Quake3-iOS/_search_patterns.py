#!/usr/bin/env python3
import os, re

filepath = "/Users/targus/Documents/Quake_IoS_Phase9_Fork/Quake3-iOS/MetalView.swift"

with open(filepath, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

print(f"Total lines read: {len(lines)}")
print()

# Pattern 1: draworder (case insensitive)
print("### Pattern 1 (draworder - case insensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "draworder" in line.lower():
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 2: draw_order (case insensitive)
print("### Pattern 2 (draw_order - case insensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "draw_order" in line.lower():
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 3: drawOrder (case sensitive)
print("### Pattern 3 (drawOrder - case sensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "drawOrder" in line:
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 4: DrawOrder (case sensitive)
print("### Pattern 4 (DrawOrder - case sensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "DrawOrder" in line:
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 5: draw AND order on same line (case insensitive)
print("### Pattern 5 (draw.*order - case insensitive, both words on same line)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    lower = line.lower()
    if "draw" in lower and "order" in lower:
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 6: renderPassOrder (case sensitive)
print("### Pattern 6 (renderPassOrder - case sensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "renderPassOrder" in line:
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}\n")

# Pattern 7: drawable (case insensitive)
print("### Pattern 7 (drawable - case insensitive)")
print("| Line | Text |")
print("|------|------|")
count = 0
for i, line in enumerate(lines, 1):
    if "drawable" in line.lower():
        print(f"| {i:4d} | `{line.rstrip()}` |")
        count += 1
if count == 0:
    print("NO MATCHES FOUND")
print(f"\nTotal matches: {count}")
