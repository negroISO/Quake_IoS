#!/usr/bin/env python3
"""
pbr_extract_hash_table.py — parse an RTX Remix mod.usda and emit a JSON
table mapping `<original_d3d9_texture_hash> -> { albedo, normal,
roughness, metallic, emissive, height }` of relative .dds paths.

NVIDIA RTX Remix identifies the original D3D9 texture to replace via a
content hash that's encoded into the material primitive name in the USDA:

    over "mat_D5D774A75BFB47EC"
    {
        over "Shader"
        {
            asset inputs:diffuse_texture     = @./assets/ingested/<name>.a.rtex.dds@
            asset inputs:normalmap_texture   = @./assets/ingested/<name>_OTH_Normal.n.rtex.dds@
            asset inputs:roughness_texture   = @./assets/ingested/<name>.r.rtex.dds@
            asset inputs:metallic_texture    = @./assets/ingested/<name>.m.rtex.dds@
            asset inputs:emissive_mask_texture = @./assets/ingested/<name>.e.rtex.dds@
            asset inputs:height_texture      = @./assets/ingested/<name>.h.rtex.dds@
            ...optional emissive_intensity, emissive_color, etc.
        }
    }

This script is intentionally regex-driven — we don't pull in pxr/USD to
keep the toolchain small. The USDA file is plain ASCII with predictable
structure (single mat_<hash> per `over` block; Shader sub-block lists
the texture asset paths).

USAGE
    scripts/pbr_extract_hash_table.py <mod.usda> <out.json>

OUTPUT JSON SCHEMA
    {
      "version": 1,
      "source": "<mod.usda absolute path>",
      "material_count": <int>,
      "materials": {
          "D5D774A75BFB47EC": {
              "albedo":    "assets/ingested/<name>.a.rtex.dds" | null,
              "normal":    "assets/ingested/<name>.n.rtex.dds" | null,
              "roughness": "assets/ingested/<name>.r.rtex.dds" | null,
              "metallic":  "assets/ingested/<name>.m.rtex.dds" | null,
              "emissive":  "assets/ingested/<name>.e.rtex.dds" | null,
              "height":    "assets/ingested/<name>.h.rtex.dds" | null,
              "emissive_intensity": 24.0 | null,
              "emissive_color":     [r, g, b] | null
          },
          ...
      }
    }

EXIT
    0 on success, prints the JSON header + stats to stderr.
"""

import json
import re
import sys
from pathlib import Path


# Regex to find a `mat_<HEX>` block opening line. Hex is uppercase A-F,
# 16 chars (64-bit). RTX Remix uses uppercase hex consistently.
MAT_RE = re.compile(r'^\s*over\s+"mat_([0-9A-Fa-f]{16})"\s*$')

# Asset-path regex inside the Shader block. RTX Remix uses
#     <type> inputs:<key> = @./relative/path/to/file.dds@
ASSET_RE = re.compile(r'inputs:(\S+?)\s*=\s*@(.+?\.dds)@')

# Emissive numeric inputs.
EMISSIVE_INTENSITY_RE = re.compile(r'inputs:emissive_intensity\s*=\s*([0-9.eE+-]+)')
EMISSIVE_COLOR_RE = re.compile(r'inputs:emissive_color_constant\s*=\s*\(\s*([0-9.eE+-]+)\s*,\s*([0-9.eE+-]+)\s*,\s*([0-9.eE+-]+)\s*\)')

# Map RTX Remix asset-input keys to our short slot names. Variations exist
# because the Aperture PBR_Opacity schema has slightly different names than
# Aperture PBR_Translucent. We accept either.
KEY_ALIASES = {
    'diffuse_texture':          'albedo',
    'diffuseTexture':           'albedo',
    'albedo_texture':           'albedo',
    'normalmap_texture':        'normal',
    'normal_texture':           'normal',
    'roughness_texture':        'roughness',
    'reflectionroughness_texture': 'roughness',
    'metallic_texture':         'metallic',
    'metallic_constant':        None,           # ignore scalar constants
    'emissive_mask_texture':    'emissive',
    'emissive_texture':         'emissive',
    'height_texture':           'height',
    'displacement_texture':     'height',
}


def parse_mod_usda(path: Path) -> dict:
    materials: dict[str, dict] = {}

    text = path.read_text(encoding='utf-8', errors='replace')

    # Walk by lines; a `over "mat_<HEX>"` opens a block. Track depth via
    # naive brace counting — USDA `{ ... }` is reliable inside an
    # `over` block. When the block's depth returns to 0, we close.
    cur_hash: str | None = None
    cur_data: dict = {}
    depth = 0

    for raw in text.splitlines():
        line = raw.rstrip('\r')

        if cur_hash is None:
            m = MAT_RE.match(line)
            if m:
                cur_hash = m.group(1).upper()
                cur_data = {
                    'albedo':    None,
                    'normal':    None,
                    'roughness': None,
                    'metallic':  None,
                    'emissive':  None,
                    'height':    None,
                    'emissive_intensity': None,
                    'emissive_color':     None,
                }
                depth = 0
            continue

        # We're inside a mat_ block. Track braces.
        depth += line.count('{')
        depth -= line.count('}')

        # Asset paths
        for m in ASSET_RE.finditer(line):
            key, path_str = m.group(1), m.group(2)
            slot = KEY_ALIASES.get(key)
            if slot is None:
                continue
            # Strip leading "./" — paths in mod.usda are relative to the
            # mod.usda directory, which is what we want.
            if path_str.startswith('./'):
                path_str = path_str[2:]
            cur_data[slot] = path_str

        # Emissive numerics
        m = EMISSIVE_INTENSITY_RE.search(line)
        if m:
            try:
                cur_data['emissive_intensity'] = float(m.group(1))
            except ValueError:
                pass

        m = EMISSIVE_COLOR_RE.search(line)
        if m:
            try:
                cur_data['emissive_color'] = [float(m.group(i)) for i in (1, 2, 3)]
            except ValueError:
                pass

        # Block closed
        if depth <= 0:
            # Only emit if the material actually has at least one texture
            # binding — otherwise it's an `over` placeholder with no data.
            if any(cur_data[k] for k in ('albedo', 'normal', 'roughness',
                                         'metallic', 'emissive', 'height')):
                materials[cur_hash] = cur_data
            cur_hash = None
            cur_data = {}
            depth = 0

    return materials


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    in_path = Path(sys.argv[1]).expanduser().resolve()
    out_path = Path(sys.argv[2]).expanduser().resolve()

    if not in_path.is_file():
        print(f'[err] mod.usda not readable at {in_path}', file=sys.stderr)
        return 1

    materials = parse_mod_usda(in_path)

    # Stats on what we found.
    counts = {k: 0 for k in ('albedo', 'normal', 'roughness', 'metallic', 'emissive', 'height')}
    emissive_materials = 0
    for h, d in materials.items():
        for k in counts:
            if d[k]:
                counts[k] += 1
        if d['emissive_intensity'] and d['emissive_intensity'] > 0:
            emissive_materials += 1

    # Phase 1 Path A: extract DESCRIPTIVELY-NAMED materials (not pure hex)
    # for direct Q3-shader-name binding. The .dds asset paths look like:
    #   assets/ingested/<stem>_albedo.a.rtex.dds      (descriptive stem)
    #   assets/ingested/<HEX>_albedo.a.rtex.dds       (RUNO auto-named)
    # We extract the leading path-component stem and key a by_name map
    # off it. Q3 shader names like 'models/ammo/rocket/rocket' get
    # normalized at lookup time (basename, lowercase) and matched.
    materials_by_name = {}
    HEX16_RE = re.compile(r'^[0-9A-F]{16}')
    for h, d in materials.items():
        # Pick any non-null slot to recover the stem
        for slot in ('albedo', 'normal', 'roughness', 'metallic', 'emissive', 'height'):
            p = d[slot]
            if not p:
                continue
            # Path is "assets/ingested/<stem>_<type>.<suffix>.rtex.dds"
            basename = p.rsplit('/', 1)[-1]
            # Strip everything after the first known type suffix
            stem = basename
            for marker in ('_albedo.', '_normal_OTH_Normal', '_normal.',
                           '_roughness.', '_metallic.', '_emissive.', '_height',
                           '.a.rtex', '.n.rtex', '.r.rtex', '.m.rtex',
                           '.e.rtex', '.h.rtex', '.dds'):
                idx = stem.find(marker)
                if idx > 0:
                    stem = stem[:idx]
                    break
            # Skip empty + pure-hex names (those need the content hash)
            if not stem or HEX16_RE.match(stem):
                continue
            key = stem.lower()
            # First-write-wins (deterministic across re-runs)
            if key not in materials_by_name:
                materials_by_name[key] = {
                    'hash': h,
                    'albedo':    d['albedo'],
                    'normal':    d['normal'],
                    'roughness': d['roughness'],
                    'metallic':  d['metallic'],
                    'emissive':  d['emissive'],
                    'height':    d['height'],
                    'emissive_intensity': d['emissive_intensity'],
                    'emissive_color':     d['emissive_color'],
                }
            break

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open('w', encoding='utf-8') as f:
        json.dump({
            'version': 2,
            'source': str(in_path),
            'material_count': len(materials),
            'counts': counts,
            'emissive_materials': emissive_materials,
            'name_indexed_count': len(materials_by_name),
            'materials': materials,
            'materials_by_name': materials_by_name,
        }, f, indent=2)
    print(f'  by_name: {len(materials_by_name)} entries (descriptive stems)', file=sys.stderr)

    print(f'[ok] wrote {len(materials)} materials → {out_path}', file=sys.stderr)
    print(f'  albedo:   {counts["albedo"]}', file=sys.stderr)
    print(f'  normal:   {counts["normal"]}', file=sys.stderr)
    print(f'  roughness:{counts["roughness"]}', file=sys.stderr)
    print(f'  metallic: {counts["metallic"]}', file=sys.stderr)
    print(f'  emissive: {counts["emissive"]}', file=sys.stderr)
    print(f'  height:   {counts["height"]}', file=sys.stderr)
    print(f'  emissive intensity > 0:  {emissive_materials}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
