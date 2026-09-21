#!/usr/bin/env python3
"""Restore verified q3dm17 DDS files and reject the known wrong q3dm6 match.

Usage: repair_q3_comparison_assets.py --pbr Resources/baseq3/pbr
       --export /path/to/export_for_mac/textures_dds
Game assets stay local; the checked-in manifest verifies their identity.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pbr', required=True, type=Path)
    parser.add_argument('--export', required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name('q3dm17_asset_manifest.json').read_text())
    materials = args.pbr / 'materials.json'
    data = json.loads(materials.read_text())
    planned = []
    for row in manifest:
        src = args.export / row['file']
        dst = args.pbr / 'assets/ingested' / row['file']
        candidate = dst if dst.exists() else src
        if not candidate.is_file() or hashlib.sha256(candidate.read_bytes()).hexdigest() != row['sha256']:
            raise SystemExit(f'Missing or different asset (no files changed): {candidate}')
        if not dst.exists():
            planned.append((src, dst))
    name = 'textures/gothic_block/blocks18cgeomtrnx'
    entry = data.get('materials_by_name', {}).get(name, {})
    reject = entry.get('hash') == 'BB9CB6998E4845D0'
    if reject:
        backup = materials.with_name('materials.before-column-repair.json')
        if not backup.exists():
            shutil.copy2(materials, backup)
        del data['materials_by_name'][name]
        temp = materials.with_suffix('.json.tmp')
        temp.write_text(json.dumps(data, indent=1) + '\n')
        temp.replace(materials)
    for src, dst in planned:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    print(json.dumps({'verified': len(manifest), 'restored': len(planned),
                      'rejected_skull_assignment': reject, 'pbr': str(args.pbr)}))


if __name__ == '__main__':
    main()
