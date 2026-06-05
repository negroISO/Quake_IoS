#!/usr/bin/env python3
"""Batch curate map-specific PBR folders from pk3-contained Q3 BSPs.

Usage:
  scripts/curate_maps.py <pak.pk3> <full_materials.json> <rtx_assets_root> <output_root> <map> [<map> ...]

If `full_materials.json` was generated directly from mod.usda, first apply a
BlueAmulet xxhash texture map so it has real Q3 shader names:

  scripts/pbr_apply_txrmap.py docs/pbr/q3rtx_v07_materials.json txrmap.txt /tmp/q3rtx_v07_named.json

Example:
  scripts/curate_maps.py baseq3/pak0.pk3 /tmp/q3rtx_v07_named.json \
    "/Users/targus/Downloads/Quake III Arena RTX v0.7/rtx-remix/mods/q3rtx_v07/assets" \
    /tmp/q3_pbr_maps q3dm1 q3dm4 q3dm6 q3dm17 nv15
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def run(cmd: list[str]) -> None:
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True)


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        raise SystemExit(__doc__)
    root = Path(__file__).resolve().parents[1]
    pak = Path(argv[1])
    materials = Path(argv[2])
    assets = Path(argv[3])
    out_root = Path(argv[4])
    maps = argv[5:]

    shader_tool = root / "scripts" / "bsp_shader_names.py"
    filter_tool = root / "scripts" / "filter_rtx_assets.py"
    out_root.mkdir(parents=True, exist_ok=True)

    for map_name in maps:
        bsp = f"maps/{map_name}.bsp"
        shader_list = out_root / f"{map_name}_shaders.txt"
        map_out = out_root / map_name
        print(f"\n=== {map_name} ===", flush=True)
        run([sys.executable, str(shader_tool), str(pak), bsp, str(shader_list)])
        run([sys.executable, str(filter_tool), str(materials), str(shader_list), str(assets), str(map_out)])
        print(f"wrote: {map_out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
