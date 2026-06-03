#!/usr/bin/env python3
"""Stage just the DDS textures referenced by `materials_by_name` (the
~21 descriptively-named PBR materials) from the 14 GB RTX Remix mod
into a curated bundle-shippable subset.

USAGE
  scripts/pbr_stage_named_assets.py <materials.json> <mod_asset_root> <out_dir>

OUT_DIR LAYOUT
  <out_dir>/pbr/materials.json          (copied verbatim)
  <out_dir>/pbr/assets/ingested/...dds  (just the named ones)

We deliberately omit hex-keyed materials (~830 of them) because the
hash function for RTX Remix mat_<HEX> keys remains undetermined
(see docs/PBR-PHASE-1-HASH-STATUS.md). The curated subset typically
runs ~30-80 MB instead of 14 GB.
"""

import json
import shutil
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    json_path = Path(sys.argv[1]).expanduser().resolve()
    asset_root = Path(sys.argv[2]).expanduser().resolve()
    out_dir = Path(sys.argv[3]).expanduser().resolve()

    data = json.loads(json_path.read_text())
    by_name = data.get('materials_by_name', {})

    # Destination tree
    out_pbr = out_dir / 'pbr'
    out_assets = out_pbr / 'assets' / 'ingested'
    out_assets.mkdir(parents=True, exist_ok=True)

    # Copy the JSON (referenced at runtime by bundle path)
    shutil.copy2(json_path, out_pbr / 'materials.json')

    # Walk the named materials, collect all .dds paths, copy them
    copied = 0
    missing = 0
    total_bytes = 0
    for name, mat in by_name.items():
        for slot in ('albedo', 'normal', 'roughness', 'metallic',
                     'emissive', 'height'):
            rel = mat.get(slot)
            if not rel:
                continue
            # `rel` is an absolute path resolved by the C-side loader at
            # runtime; in the JSON it's like:
            #   "/Users/.../rtx-remix/mods/q3rtx_v07/assets/ingested/rocket.a.rtex.dds"
            # We want just the basename for the bundle.
            src = Path(rel)
            # If JSON has absolute paths, src is already absolute.
            # If JSON has relative paths, joined under asset_root.
            if not src.is_absolute():
                src = asset_root / rel
            dst = out_assets / src.name
            if not src.exists():
                print(f'[miss] {name}/{slot}: {src}', file=sys.stderr)
                missing += 1
                continue
            if not dst.exists() or dst.stat().st_size != src.stat().st_size:
                shutil.copy2(src, dst)
            copied += 1
            total_bytes += src.stat().st_size

    # Rewrite the JSON's `materials_by_name` paths to bundle-relative form
    # so the C-side loader can prepend NSBundle.resourcePath at boot.
    rewritten = {}
    for name, mat in by_name.items():
        m = dict(mat)
        for slot in ('albedo', 'normal', 'roughness', 'metallic',
                     'emissive', 'height'):
            v = m.get(slot)
            if v:
                # Replace with just the basename
                m[slot] = 'assets/ingested/' + Path(v).name
        rewritten[name] = m
    data['materials_by_name'] = rewritten
    # Also strip the giant materials block — the bundle only ships the
    # name-keyed subset; hex-keyed lookups won't fire without the hash.
    data['materials'] = {}
    data['source'] = '<bundled>'
    (out_pbr / 'materials.json').write_text(json.dumps(data, indent=2))

    print(f'[stage] {copied} files copied, {missing} missing, '
          f'{total_bytes / (1024*1024):.1f} MiB total', file=sys.stderr)
    print(f'[stage] tree at {out_pbr}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
