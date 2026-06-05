#!/usr/bin/env python3
"""Audit whether an RTX Remix USDA contains original game texture/shader paths.

Usage:
  scripts/pbr_usda_source_audit.py <mod.usda>

This distinguishes replacement-material data (mat_<hash> + assets/ingested DDS)
from the missing original-source mapping (textures/... / models/... / gfx/...).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SOURCE_PATTERNS = (r"textures/", r"models/", r"gfx/", r"sprites/", r"menu/", r"powerups/")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        raise SystemExit(__doc__)
    path = Path(argv[1]).expanduser()
    if not path.is_file():
        raise SystemExit(f"[err] not found: {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    mat_count = len(re.findall(r'over\s+"mat_[0-9A-Fa-f]{16}"', text))
    def_mat_count = len(re.findall(r"def\s+Material", text))
    ingested_count = text.lower().count("assets/ingested")
    source_hits = {pat: len(re.findall(pat, text, re.IGNORECASE)) for pat in SOURCE_PATTERNS}
    total_source_hits = sum(source_hits.values())
    print(f"file: {path}")
    print(f"over mat_<hash>: {mat_count}")
    print(f"def Material: {def_mat_count}")
    print(f"assets/ingested refs: {ingested_count}")
    for pat, count in source_hits.items():
        print(f"{pat} refs: {count}")
    if total_source_hits == 0:
        print("result: NO original Q3 source texture/shader paths found in this USDA")
        print("meaning: it cannot generate txrmap.txt by itself; it only maps hash -> replacement DDS")
        return 1
    print("result: source-like paths found; inspect before using as txrmap source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
