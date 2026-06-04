#!/usr/bin/env python3
"""Extract unique shader names from a Quake 3 BSP shader/texture lump.

Usage:
  scripts/bsp_shader_names.py <map.bsp> [output.txt]
  scripts/bsp_shader_names.py <pak.pk3> maps/q3dm1.bsp [output.txt]
"""
from __future__ import annotations

import struct
import sys
import zipfile
from pathlib import Path

BSP_IDENT = b"IBSP"
Q3_BSP_VERSION = 46
LUMP_SHADERS = 1
SHADER_ENTRY_SIZE = 64 + 4 + 4
LUMP_COUNT = 17


def read_bsp_bytes(argv: list[str]) -> tuple[bytes, str, int]:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    first = Path(argv[1])
    if first.suffix.lower() == ".pk3":
        if len(argv) < 3:
            raise SystemExit("pk3 mode needs inner BSP path, e.g. maps/q3dm1.bsp")
        inner = argv[2].replace("\\", "/")
        with zipfile.ZipFile(first) as zf:
            data = zf.read(inner)
        return data, f"{first}:{inner}", 3
    return first.read_bytes(), str(first), 2


def extract_shaders(data: bytes) -> list[str]:
    if len(data) < 8 + LUMP_COUNT * 8 or data[:4] != BSP_IDENT:
        raise ValueError("not a valid IBSP file")
    version = struct.unpack_from("<i", data, 4)[0]
    if version != Q3_BSP_VERSION:
        raise ValueError(f"unsupported BSP version {version}; expected {Q3_BSP_VERSION}")

    lumps = [struct.unpack_from("<ii", data, 8 + i * 8) for i in range(LUMP_COUNT)]
    off, length = lumps[LUMP_SHADERS]
    if off < 0 or length < 0 or off + length > len(data):
        raise ValueError("shader lump is out of file bounds")
    if length % SHADER_ENTRY_SIZE:
        print(f"warning: shader lump length {length} is not a multiple of {SHADER_ENTRY_SIZE}", file=sys.stderr)

    shaders: set[str] = set()
    blob = data[off : off + length]
    for i in range(length // SHADER_ENTRY_SIZE):
        raw = blob[i * SHADER_ENTRY_SIZE : i * SHADER_ENTRY_SIZE + 64]
        name = raw.split(b"\x00", 1)[0].decode("ascii", errors="ignore").strip()
        if name:
            shaders.add(name)
    return sorted(shaders)


def main(argv: list[str]) -> int:
    data, source, next_arg = read_bsp_bytes(argv)
    shaders = extract_shaders(data)
    if len(argv) > next_arg:
        out = Path(argv[next_arg])
        out.write_text("\n".join(shaders) + ("\n" if shaders else ""))
        print(f"Wrote {len(shaders)} shaders from {source} to {out}")
    else:
        for shader in shaders:
            print(shader)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
