"""Compute RTX Remix material hashes for every texture in Quake 3's pak0
and merge any matches against capture_materials_report.csv into the
canonical materials.json.

RTX Remix hash formula (cracked + validated by dds_hash_validate.py):
    RTX_hash = XXH3_64( mip0 reinterpreted as BGRA )
i.e. take the decoded RGBA8 pixel buffer, swap R<->B channels, xxh3_64.

Output entries are keyed by the engine-side asset name (extension stripped,
matching Q3's shader-path convention, e.g. "textures/gothic_block/foo").
"""

import csv
import io
import json
import os
import sys
import time
import zipfile
from pathlib import Path

import xxhash
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
MATERIALS_JSON = REPO / "Resources" / "baseq3" / "pbr" / "materials.json"
CSV_REPORT = Path("/Users/targus/Desktop/capture_materials_report.csv")
PAK0 = REPO / "baseq3" / "pak0.pk3"
BACKUP_DIR = REPO / "Resources" / "baseq3" / "pbr" / "_bak"

# Q3 reads these extensions, in priority order, when loading a texture by
# name. RTX Remix hashes whatever pixels the engine actually uploads, so
# we hash each extension we find — if the runtime picked the .tga version
# its hash will be different from the .jpg version of the same name.
TEXTURE_EXTENSIONS = (".tga", ".jpg", ".jpeg", ".png")


def rtx_hash(rgba_bytes: bytes) -> str:
    """Apply the validated RTX Remix hash formula to mip0 RGBA pixel data."""
    mv = bytearray(rgba_bytes)
    mv[0::4], mv[2::4] = mv[2::4], mv[0::4]  # RGBA -> BGRA
    return f"{xxhash.xxh3_64(bytes(mv)).intdigest():016X}"


def texture_to_rgba8(blob: bytes) -> bytes | None:
    try:
        img = Image.open(io.BytesIO(blob))
        img = img.convert("RGBA")
        return img.tobytes()
    except Exception:
        return None


def hash_pak0_textures(pak_path: Path) -> dict[str, list[tuple[str, str]]]:
    """Return dict mapping hash -> list of (q3_name, format_ext) tuples."""
    out: dict[str, list[tuple[str, str]]] = {}
    total = 0
    decoded = 0
    skipped = 0
    with zipfile.ZipFile(pak_path) as z:
        for info in z.infolist():
            name_lower = info.filename.lower()
            if not name_lower.endswith(TEXTURE_EXTENSIONS):
                continue
            total += 1
            try:
                blob = z.read(info)
            except Exception:
                skipped += 1
                continue
            rgba = texture_to_rgba8(blob)
            if rgba is None:
                skipped += 1
                continue
            decoded += 1
            h = rtx_hash(rgba)
            # Strip the file extension to match the engine-side asset name.
            base = os.path.splitext(info.filename)[0]
            ext = os.path.splitext(info.filename)[1].lower().lstrip(".")
            out.setdefault(h, []).append((base, ext))
    print(f"[pak0] total textures considered: {total}, decoded: {decoded}, skipped: {skipped}")
    print(f"[pak0] unique hashes: {len(out)}")
    return out


def load_csv_pbr_rows(csv_path: Path) -> dict[str, dict]:
    """Return dict mapping hex hash (16 chars, no 0x) -> parsed row."""
    out = {}
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            hash_str = (row.get("hash") or "").strip()
            if hash_str.startswith("0x"):
                hash_str = hash_str[2:]
            hash_str = hash_str.upper()
            if len(hash_str) != 16:
                continue
            try:
                pbr = json.loads(row.get("pbrTextures") or "{}")
            except Exception:
                pbr = {}
            try:
                consts = json.loads(row.get("constants") or "{}")
            except Exception:
                consts = {}
            out[hash_str] = {
                "pbr": pbr,
                "constants": consts,
                "captures": (row.get("captures") or "").split(";"),
                "notes": row.get("notes") or "",
            }
    return out


def csv_row_to_material_entry(row: dict, hash_str: str) -> dict:
    """Project a CSV row onto the materials_by_name schema."""
    pbr = row["pbr"]
    consts = row["constants"]

    def _path(key_in_pbr: str) -> str | None:
        val = pbr.get(key_in_pbr)
        if not val:
            return None
        # CSV stores them as "./assets/ingested/...dds"; canonical schema
        # uses repo-relative "assets/ingested/...dds".
        if val.startswith("./"):
            return val[2:]
        return val

    def _const(key: str):
        val = consts.get(key)
        if val is None or val == "":
            return None
        try:
            return float(val)
        except (TypeError, ValueError):
            return None

    rough_const = _const("reflection_roughness_constant")
    metal_const = _const("metallic_constant")
    entry = {
        "hash": hash_str,
        "albedo": _path("diffuse_texture"),
        "normal": _path("normalmap_texture"),
        "roughness": _path("reflectionroughness_texture"),
        "metallic": _path("metallic_texture"),
        "height": _path("height_texture"),
        "emissive": _path("emissive_mask_texture") or _path("emissive_texture"),
    }
    if rough_const is not None:
        entry["roughness_constant"] = rough_const
    if metal_const is not None:
        entry["metallic_constant"] = metal_const
    # Strip None fields so they don't crowd the JSON, but keep the keys we
    # care about as explicit nulls when paired with a constant for that slot
    # (matches the existing schema convention).
    return {k: v for k, v in entry.items() if v is not None}


def main():
    if not PAK0.exists():
        print(f"FATAL: pak0 missing at {PAK0}", file=sys.stderr)
        sys.exit(2)
    if not CSV_REPORT.exists():
        print(f"FATAL: CSV missing at {CSV_REPORT}", file=sys.stderr)
        sys.exit(2)
    if not MATERIALS_JSON.exists():
        print(f"FATAL: materials.json missing at {MATERIALS_JSON}", file=sys.stderr)
        sys.exit(2)

    t0 = time.time()
    print(f"[bridge] hashing pak0 textures from {PAK0}")
    hash_to_q3 = hash_pak0_textures(PAK0)
    print(f"[bridge] pak0 walk took {time.time() - t0:.1f}s")

    print(f"[bridge] loading CSV: {CSV_REPORT}")
    csv_rows = load_csv_pbr_rows(CSV_REPORT)
    csv_hashes = set(csv_rows.keys())
    print(f"[bridge] CSV hashes: {len(csv_hashes)}")

    matches = csv_hashes & set(hash_to_q3.keys())
    print(f"[bridge] HASH MATCHES: {len(matches)} (out of {len(csv_hashes)} CSV hashes)")

    print(f"[bridge] loading {MATERIALS_JSON}")
    with open(MATERIALS_JSON) as f:
        canon = json.load(f)
    by_name = canon.setdefault("materials_by_name", {})

    added = 0
    upgraded = 0
    examples_added = []
    examples_upgraded = []
    for h in sorted(matches):
        row = csv_rows[h]
        new_entry = csv_row_to_material_entry(row, h)
        for q3_name, ext in hash_to_q3[h]:
            existing = by_name.get(q3_name)
            if existing is None:
                merged = dict(new_entry)
                merged["sourceTexture"] = f"{q3_name}.{ext}"
                merged["bridgeSource"] = "rtx_remix_capture"
                by_name[q3_name] = merged
                added += 1
                if len(examples_added) < 20:
                    examples_added.append(q3_name)
            else:
                # Existing entry — only upgrade slots that are missing.
                upgrade_done = False
                for key in ("albedo", "normal", "roughness", "metallic", "height",
                            "emissive", "roughness_constant", "metallic_constant"):
                    if not existing.get(key) and new_entry.get(key):
                        existing[key] = new_entry[key]
                        upgrade_done = True
                if upgrade_done:
                    existing.setdefault("hash", h)
                    existing["bridgeSource"] = "rtx_remix_capture"
                    upgraded += 1
                    if len(examples_upgraded) < 20:
                        examples_upgraded.append(q3_name)

    metadata = canon.setdefault("metadata", {})
    metadata["bridge_at_unix"] = int(time.time())
    metadata["bridge_matches"] = len(matches)
    metadata["bridge_added"] = added
    metadata["bridge_upgraded"] = upgraded

    # Backup current materials.json before overwriting.
    BACKUP_DIR.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = BACKUP_DIR / f"materials.pre-bridge.{stamp}.json.bak"
    with open(backup_path, "w") as f:
        with open(MATERIALS_JSON) as src:
            f.write(src.read())
    print(f"[bridge] backed up pre-bridge materials.json -> {backup_path}")

    # Atomic write.
    tmp = MATERIALS_JSON.with_suffix(".bridge.tmp")
    with open(tmp, "w") as f:
        json.dump(canon, f, indent=2, sort_keys=False)
    os.replace(tmp, MATERIALS_JSON)
    new_size = MATERIALS_JSON.stat().st_size
    print(f"[bridge] wrote {MATERIALS_JSON} ({new_size:,} bytes)")
    print(f"[bridge] materials_by_name now: {len(by_name)} entries")
    print(f"[bridge] added: {added}  upgraded: {upgraded}")
    print(f"[bridge] sample additions: {examples_added[:10]}")
    print(f"[bridge] sample upgrades: {examples_upgraded[:10]}")

    # Force Stage baseq3 to re-stage on next build.
    os.utime(REPO / "Resources" / "baseq3", None)
    print(f"[bridge] touched {REPO/'Resources'/'baseq3'} to trigger restage")


if __name__ == "__main__":
    main()
