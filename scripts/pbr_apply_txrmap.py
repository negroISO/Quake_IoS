#!/usr/bin/env python3
"""Add original Q3 shader names to an RTX Remix materials.json using txrmap output.

Usage:
  scripts/pbr_apply_txrmap.py <materials.json> <txrmap.txt|txrmap.json> <out.json>

Accepted txrmap formats:
  - BlueAmulet/RTXRemixStuff xxhash-txrmap.py text lines:
      0xD5D774A75BFB47EC textures/base_wall/foo.dds
      D5D774A75BFB47EC textures/base_wall/foo.tga
  - JSON dicts/lists containing a hash-like field and a path-like field.

Output is the same material schema, but every matched material gets:
  - "shaderName": original texture path with extension stripped/lowercased
  - "sourceTexture": original path from txrmap
and materials_by_name is rebuilt with exact shaderName keys.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable

TEXTURE_KEYS = ("albedo", "normal", "roughness", "metallic", "emissive", "height")
HASH_RE = re.compile(r"^(?:0x)?([0-9A-Fa-f]{16})$")
EXT_RE = re.compile(r"\.(?:tga|jpg|jpeg|png|dds|bmp|webp)$", re.IGNORECASE)
PATH_HINT_RE = re.compile(r"[\\/]|\.(?:tga|jpg|jpeg|png|dds|bmp|webp)$", re.IGNORECASE)
HASH_KEYS = ("hash", "textureHash", "texture_hash", "xxhash", "xxh3", "id", "material", "mat")
PATH_KEYS = ("path", "texture", "source", "sourceTexture", "source_texture", "original", "originalPath", "original_path", "file", "filename", "name")


def norm_hash(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if text.startswith("mat_"):
        text = text[4:]
    m = HASH_RE.match(text)
    return m.group(1).upper() if m else None


def norm_path(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip().strip('"').strip("'")
    if not text:
        return None
    text = text.replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    return text


def shader_name_from_path(path: str) -> str:
    path = norm_path(path) or ""
    return EXT_RE.sub("", path).lower()


def parse_text_mapping(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        # Keep comments after the path from becoming part of it.
        line = re.split(r"\s+#|\s+//", line, maxsplit=1)[0].strip()
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        h = norm_hash(parts[0])
        p = norm_path(parts[1])
        if h and p:
            out[h] = p
    return out


def walk_json(obj: Any) -> Iterable[dict[str, Any]]:
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from walk_json(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_json(v)


def parse_json_mapping(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out: dict[str, str] = {}

    # Common direct dict form: {"0xHASH": "textures/..."} or {"HASH": {...}}
    if isinstance(data, dict):
        for k, v in data.items():
            h = norm_hash(k)
            if h:
                if isinstance(v, str):
                    p = norm_path(v)
                    if p:
                        out[h] = p
                elif isinstance(v, dict):
                    p = first_path(v)
                    if p:
                        out[h] = p

    for d in walk_json(data):
        h = first_hash(d)
        p = first_path(d)
        if h and p:
            out[h] = p
    return out


def first_hash(d: dict[str, Any]) -> str | None:
    for key in HASH_KEYS:
        if key in d:
            h = norm_hash(d[key])
            if h:
                return h
    for v in d.values():
        h = norm_hash(v)
        if h:
            return h
    return None


def first_path(d: dict[str, Any]) -> str | None:
    for key in PATH_KEYS:
        if key in d:
            p = norm_path(d[key])
            if p and PATH_HINT_RE.search(p) and not norm_hash(p):
                return p
    for v in d.values():
        if isinstance(v, str):
            p = norm_path(v)
            if p and PATH_HINT_RE.search(p) and not norm_hash(p):
                return p
    return None


def parse_mapping(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace").lstrip()
    if text.startswith("{") or text.startswith("["):
        return parse_json_mapping(path)
    return parse_text_mapping(path)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        raise SystemExit(__doc__)
    materials_path = Path(argv[1])
    mapping_path = Path(argv[2])
    out_path = Path(argv[3])

    if not materials_path.is_file():
        raise SystemExit(f"[err] materials.json not found: {materials_path}")
    if not mapping_path.is_file():
        raise SystemExit(
            f"[err] txrmap file not found: {mapping_path}\n"
            "Generate/provide it first, e.g.:\n"
            "  python /path/to/xxhash-txrmap.py <original_textures_folder> txrmap.txt\n"
            "Then rerun pbr_apply_txrmap.py with that txrmap path."
        )

    full = json.loads(materials_path.read_text(encoding="utf-8"))
    mapping = parse_mapping(mapping_path)
    materials = full.get("materials", {})
    if not isinstance(materials, dict):
        raise SystemExit("[err] materials.json missing object 'materials'")

    matched = 0
    unmatched_mapping = 0
    by_name: dict[str, dict[str, Any]] = {}
    for h, source_path in sorted(mapping.items()):
        mat = materials.get(h)
        if mat is None:
            mat = materials.get(h.upper()) or materials.get(h.lower())
        if not isinstance(mat, dict):
            unmatched_mapping += 1
            continue
        shader_name = shader_name_from_path(source_path)
        mat["hash"] = h
        mat["shaderName"] = shader_name
        mat["sourceTexture"] = norm_path(source_path)
        by_name[shader_name] = mat
        matched += 1

    # Preserve any existing named records too, but prefer exact txrmap names.
    for name, mat in full.get("materials_by_name", {}).items():
        if isinstance(mat, dict):
            key = shader_name_from_path(str(mat.get("shaderName") or name))
            by_name.setdefault(key, mat)

    full["materials_by_name"] = by_name
    meta = dict(full.get("metadata", {})) if isinstance(full.get("metadata"), dict) else {}
    meta.update({
        "txrmap_source": str(mapping_path),
        "txrmap_entries": len(mapping),
        "txrmap_matched_materials": matched,
        "txrmap_unmatched_entries": unmatched_mapping,
        "materials_by_name_count": len(by_name),
    })
    full["metadata"] = meta
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(full, indent=2), encoding="utf-8")
    print(f"txrmap entries: {len(mapping)}")
    print(f"matched materials: {matched}")
    print(f"unmatched txrmap entries: {unmatched_mapping}")
    print(f"materials_by_name: {len(by_name)}")
    print(f"output: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
