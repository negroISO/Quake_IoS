#!/usr/bin/env python3
"""Create a map-specific PBR folder from a full RTX Remix material table.

Usage:
  scripts/filter_rtx_assets.py <full_materials.json> <shader_list.txt> <rtx_assets_root> <output_pbr_dir>

Output:
  <output_pbr_dir>/materials.json
  <output_pbr_dir>/assets/ingested/*.dds
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

TEXTURE_KEYS = ("albedo", "normal", "roughness", "metallic", "emissive", "height")


def norm_name(s: str) -> str:
    s = s.strip().replace("\\", "/")
    for ext in (".tga", ".jpg", ".jpeg", ".png", ".dds"):
        if s.lower().endswith(ext):
            return s[: -len(ext)].lower()
    return s.lower()


def material_shader_name(mat: dict) -> str:
    for key in ("shaderName", "shader", "name", "source", "path"):
        v = mat.get(key)
        if isinstance(v, str) and v:
            return v
    return ""


def copy_texture(src_root: Path, out_ingested: Path, rel: str) -> tuple[str | None, bool]:
    rel_path = Path(rel.replace("\\", "/"))
    candidates = [src_root / rel_path, src_root / rel_path.name]
    for src in candidates:
        if src.exists():
            dst = out_ingested / src.name
            shutil.copy2(src, dst)
            return f"assets/ingested/{dst.name}", True
    return None, False


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        raise SystemExit(__doc__)
    materials_json = Path(argv[1])
    shader_list = Path(argv[2])
    src_root = Path(argv[3])
    out_dir = Path(argv[4])
    out_ingested = out_dir / "assets" / "ingested"
    out_ingested.mkdir(parents=True, exist_ok=True)

    wanted_raw = [ln.strip() for ln in shader_list.read_text().splitlines() if ln.strip() and not ln.strip().startswith("#")]
    wanted = {norm_name(x) for x in wanted_raw}
    wanted_parts = {part for w in wanted for part in w.split('/') if part}
    full = json.loads(materials_json.read_text())

    used_by_hash: dict[str, dict] = {}
    used_by_name: dict[str, dict] = {}

    for name, mat in full.get("materials_by_name", {}).items():
        n = norm_name(name)
        shader_n = norm_name(material_shader_name(mat))
        # Exact shader-name matches are best. The bundled extracted table only has
        # descriptive names for a small subset, so also allow conservative stem
        # matches (e.g. shader path contains "rocket" and material name is "rocket").
        if n in wanted or shader_n in wanted or n in wanted_parts:
            h = str(mat.get("hash") or mat.get("id") or name)
            used_by_hash[h] = dict(mat)
            used_by_name[name] = dict(mat)

    for h, mat in full.get("materials", {}).items():
        if norm_name(material_shader_name(mat)) in wanted:
            used_by_hash[str(h)] = dict(mat)

    copied = 0
    missing: list[str] = []
    rewritten: dict[str, dict] = {}
    for h, mat in used_by_hash.items():
        m = dict(mat)
        for key in TEXTURE_KEYS:
            rel = m.get(key)
            if not isinstance(rel, str) or not rel:
                continue
            new_rel, ok = copy_texture(src_root, out_ingested, rel)
            if ok and new_rel:
                copied += 1
                m[key] = new_rel
            else:
                missing.append(rel)
        rewritten[h] = m

    rewritten_by_name = {}
    for name, mat in used_by_name.items():
        h = str(mat.get("hash") or mat.get("id") or name)
        if h in rewritten:
            rewritten_by_name[name] = rewritten[h]

    out = {
        "metadata": {
            "source_materials_json": str(materials_json),
            "shader_list": str(shader_list),
            "wanted_shader_count": len(wanted),
            "material_count": len(rewritten),
            "copied_texture_refs": copied,
            "missing_texture_refs": len(missing),
        },
        "materials": rewritten,
        "materials_by_name": rewritten_by_name,
    }
    (out_dir / "materials.json").write_text(json.dumps(out, indent=2))
    if missing:
        (out_dir / "missing_textures.txt").write_text("\n".join(sorted(set(missing))) + "\n")
    print(f"wanted shaders: {len(wanted)}")
    print(f"materials: {len(rewritten)}")
    print(f"copied texture refs: {copied}")
    print(f"missing texture refs: {len(missing)}")
    print(f"output: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
