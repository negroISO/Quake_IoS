#!/usr/bin/env python3
import json, shutil, sys
from pathlib import Path

if len(sys.argv) != 4:
    print('usage: merge_q3rt_bridge.py <export_for_mac_dir> <pbr_dir> <out_materials_json>')
    raise SystemExit(2)
export = Path(sys.argv[1])
pbr = Path(sys.argv[2])
out = Path(sys.argv[3])
cur_path = pbr / 'materials.json'
cur = json.loads(cur_path.read_text(errors='replace')) if cur_path.exists() else {'metadata': {}, 'materials_by_name': {}, 'materials': {}}
cur.setdefault('metadata', {})
cur.setdefault('materials_by_name', {})
cur.setdefault('materials', {})

sem = json.loads((export/'q3_shader_semantics.json').read_text(errors='replace'))
cap = json.loads((export/'materials_q3rt_capture.json').read_text(errors='replace'))
copy_manifest = json.loads((export/'files_to_copy_q3rt_capture.json').read_text(errors='replace'))
full = json.loads((export/'materials_q3rt_full_source.json').read_text(errors='replace')) if (export/'materials_q3rt_full_source.json').exists() else {'materials': {}}
full_copy_manifest = json.loads((export/'files_to_copy_q3rt_full_source.json').read_text(errors='replace')) if (export/'files_to_copy_q3rt_full_source.json').exists() else {'filesToCopy': []}

# Merge shader semantics by exact Q3 shader path. Preserve existing PBR paths.
sem_added = sem_updated = 0
for name, sv in sem.get('materials_by_name', {}).items():
    e = cur['materials_by_name'].setdefault(name, {})
    if e: sem_updated += 1
    else: sem_added += 1
    for k in ['gamePath','renderCategory','alphaMode','srcBlend','dstBlend','alphaFunc','sort','surfaceparm_sky','surfaceparm_trans','skyBoxBase','faces','maps','animMaps','sourceShaderFile','sourcePk3']:
        if k in sv and sv[k] is not None:
            e[k] = sv[k]
    # Help current PBR loader classify obvious emissive semantics even before deeper alpha parser support.
    if sv.get('alphaMode') == 'ADDITIVE' and e.get('emissive_intensity') is None:
        e['emissive_intensity'] = 1.0

# Merge full-source hash materials first, then captured hash materials.
# Full-source contains the broader game material table; capture data wins when both exist.
mat_added = mat_updated = full_added = full_updated = 0
for h, mv in full.get('materials', {}).items():
    key = h.upper().removeprefix('0X')
    e = cur['materials'].setdefault(key, {})
    if e: full_updated += 1
    else: full_added += 1
    for k, v in mv.items():
        if v is not None and (k not in e or not e.get(k)):
            e[k] = v
    e['hash'] = key

for h, mv in cap.get('materials', {}).items():
    key = h.upper().removeprefix('0X')
    e = cur['materials'].setdefault(key, {})
    if e: mat_updated += 1
    else: mat_added += 1
    for k, v in mv.items():
        if v is not None:
            e[k] = v
    if not e.get('albedo') and mv.get('captureTextures'):
        e['albedo'] = mv['captureTextures'][0]
        e['source'] = 'captureTextureFallback'
    # normalize hash field for diagnostics
    e['hash'] = key

# Copy material referenced files into pbr dir.
copied = missing = 0
for manifest in (full_copy_manifest, copy_manifest):
  for item in manifest.get('filesToCopy', []):
    src = export / item['source']
    if not src.exists():
        # Windows manifests may carry absolute C:/ paths. The export bundle
        # places those same DDS files under textures_dds/ by basename.
        alt = export / 'textures_dds' / Path(item['source']).name
        if alt.exists():
            src = alt
    dst = pbr / item['dest']
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.exists() or src.stat().st_size != dst.stat().st_size:
            shutil.copy2(src, dst)
            copied += 1
    else:
        missing += 1
# Copy capture texture fallbacks referenced directly by captureTextures.
for mv in cap.get('materials', {}).values():
    for rel in mv.get('captureTextures') or []:
        src = export / rel
        dst = pbr / rel
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists() or src.stat().st_size != dst.stat().st_size:
                shutil.copy2(src, dst)
                copied += 1
        else:
            missing += 1

cur['metadata']['q3rt_bridge_merge'] = {
    'source': str(export),
    'semantics_materials_by_name': len(sem.get('materials_by_name', {})),
    'capture_hash_materials': len(cap.get('materials', {})),
    'full_source_hash_materials': len(full.get('materials', {})),
    'semantics_added': sem_added,
    'semantics_updated': sem_updated,
    'full_source_added': full_added,
    'full_source_updated': full_updated,
    'capture_added': mat_added,
    'capture_updated': mat_updated,
    'files_copied': copied,
    'files_missing': missing,
}
out.write_text(json.dumps(cur, indent=2, sort_keys=True))
print(json.dumps(cur['metadata']['q3rt_bridge_merge'], indent=2))
print('materials_by_name', len(cur['materials_by_name']), 'materials', len(cur['materials']))
