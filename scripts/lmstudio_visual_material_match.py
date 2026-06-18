#!/usr/bin/env python3
"""
lmstudio_visual_material_match.py

Windows-friendly helper for building RTX Remix legacy-hash -> Quake 3 texture-name
matches with a local LM Studio vision model.

Typical Windows usage:
  py -m pip install pillow requests
  py scripts\lmstudio_visual_material_match.py ^
    --q3-root C:\q3 ^
    --rtx-root "C:\q3\rtx-remix" ^
    --txrmap docs\txrmap.txt ^
    --out visual_match_out ^
    --prepare

Then start LM Studio Local Server with a vision model, then:
  py scripts\lmstudio_visual_material_match.py ^
    --q3-root C:\q3 ^
    --rtx-root "C:\q3\rtx-remix" ^
    --txrmap docs\txrmap.txt ^
    --out visual_match_out ^
    --match --lm-url http://127.0.0.1:1234/v1/chat/completions --model local-model

Outputs:
  visual_match_out/source_catalog.jsonl       Q3 source texture thumbnail catalog
  visual_match_out/remix_catalog.jsonl        Remix/capture thumbnail catalog keyed by hash
  visual_match_out/contact_sheets/*.jpg       Q3 labeled candidate sheets
  visual_match_out/matches.jsonl              LM Studio match guesses
  visual_match_out/materials_by_name_seed.json mapping seed for this repo

Notes:
- This does NOT require a perfect Remix txrmap. It visually compares captured
  legacy DDS thumbnails against extracted pak0/Q3 textures.
- LM Studio vision matching is heuristic; review low-confidence rows manually.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import re
import shutil
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except Exception as e:
    raise SystemExit("Install Pillow first: py -m pip install pillow\n" + str(e))

try:
    import requests
except Exception:
    requests = None

IMAGE_EXTS = {".tga", ".jpg", ".jpeg", ".png", ".bmp", ".dds"}
HASH_RE = re.compile(r"(?:0x)?([0-9A-Fa-f]{16})")
TXR_LINE_RE = re.compile(r"^\s*(?:0x)?([0-9A-Fa-f]{16})\s+(.+?)\s*$")


def norm_path(p: str) -> str:
    return p.replace("\\", "/").strip().strip('"')


def clean_shader_name(path: str) -> str:
    p = norm_path(path)
    # strip common roots if present
    for marker in ("/baseq3/", "baseq3/"):
        if marker in p.lower():
            idx = p.lower().rfind(marker)
            p = p[idx + len(marker):]
            break
    if p.lower().startswith("textures/") or p.lower().startswith("icons/") or p.lower().startswith("models/") or p.lower().startswith("gfx/") or p.lower().startswith("menu/") or p.lower().startswith("powerups/") or p.lower().startswith("sprites/"):
        pass
    p = re.sub(r"\.(tga|jpg|jpeg|png|bmp|dds)$", "", p, flags=re.I)
    return p.lower()


def safe_name(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s)[:180]


def image_to_thumb(img: Image.Image, size: int = 128) -> Image.Image:
    img = ImageOps.exif_transpose(img)
    if img.mode not in ("RGB", "RGBA"):
        img = img.convert("RGBA")
    # Composite alpha over checker/dark background so icons show up.
    if img.mode == "RGBA":
        bg = Image.new("RGBA", img.size, (18, 18, 18, 255))
        bg.alpha_composite(img)
        img = bg.convert("RGB")
    else:
        img = img.convert("RGB")
    img.thumbnail((size, size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (size, size), (20, 20, 20))
    canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2))
    return canvas


def open_image_from_bytes(data: bytes) -> Image.Image | None:
    try:
        return Image.open(io.BytesIO(data)).copy()
    except Exception:
        return None


def open_image_path(path: Path) -> Image.Image | None:
    try:
        return Image.open(path).copy()
    except Exception:
        return None


def iter_q3_images(q3_root: Path) -> Iterable[tuple[str, bytes | Path]]:
    roots = []
    if (q3_root / "baseq3").exists():
        roots.append(q3_root / "baseq3")
    roots.append(q3_root)

    seen = set()
    for root in roots:
        if not root.exists():
            continue
        # Loose files.
        for p in root.rglob("*"):
            if p.is_file() and p.suffix.lower() in IMAGE_EXTS and ".pk3" not in str(p).lower():
                rel = norm_path(str(p.relative_to(root)))
                key = rel.lower()
                if key in seen:
                    continue
                seen.add(key)
                yield rel, p
        # PK3 files.
        for pk3 in root.rglob("*.pk3"):
            try:
                with zipfile.ZipFile(pk3) as z:
                    for name in z.namelist():
                        if Path(name).suffix.lower() not in IMAGE_EXTS:
                            continue
                        key = norm_path(name).lower()
                        if key in seen:
                            continue
                        seen.add(key)
                        try:
                            yield norm_path(name), z.read(name)
                        except Exception:
                            pass
            except Exception:
                pass


def parse_txrmap(path: Path) -> dict[str, str]:
    out = {}
    if not path or not path.exists():
        return out
    text = path.read_text(errors="replace")
    if text.lstrip().startswith(("{", "[")):
        data = json.loads(text)
        def walk(x):
            if isinstance(x, dict):
                h = None; p = None
                for k, v in x.items():
                    if h is None:
                        m = HASH_RE.fullmatch(str(k).strip()) or HASH_RE.fullmatch(str(v).strip())
                        if m: h = m.group(1).upper()
                    if p is None and isinstance(v, str) and re.search(r"\.(dds|tga|jpg|png|bmp)$", v, re.I):
                        p = v
                if h and p: out[h] = p
                for v in x.values(): walk(v)
            elif isinstance(x, list):
                for v in x: walk(v)
        walk(data)
        return out
    for line in text.splitlines():
        m = TXR_LINE_RE.match(line)
        if not m:
            continue
        out[m.group(1).upper()] = norm_path(m.group(2))
    return out


def iter_remix_images(rtx_root: Path, txrmap: Path | None) -> Iterable[tuple[str, Path]]:
    seen = set()
    mapping = parse_txrmap(txrmap) if txrmap else {}
    for h, p in mapping.items():
        pp = Path(p)
        if not pp.exists():
            # Try relative to rtx root or current drive-root-ish captures path.
            candidates = [rtx_root / p, rtx_root / "captures" / "textures" / Path(p).name]
            pp = next((c for c in candidates if c.exists()), pp)
        if pp.exists() and pp.suffix.lower() in IMAGE_EXTS:
            seen.add(h)
            yield h, pp
    # Also scan common capture texture folders; hash defaults to file stem.
    for root in [rtx_root / "captures" / "textures", rtx_root / "captures", rtx_root / "mods"]:
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if not p.is_file() or p.suffix.lower() not in IMAGE_EXTS:
                continue
            m = HASH_RE.search(p.stem)
            h = m.group(1).upper() if m else p.stem.upper()
            if h in seen:
                continue
            seen.add(h)
            yield h, p


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


def prepare(args) -> None:
    out = Path(args.out)
    source_thumb_dir = out / "source_thumbs"
    remix_thumb_dir = out / "remix_thumbs"
    sheet_dir = out / "contact_sheets"
    for d in (source_thumb_dir, remix_thumb_dir, sheet_dir):
        d.mkdir(parents=True, exist_ok=True)

    print("[prepare] extracting Q3 source thumbnails...")
    source_rows = []
    for rel, src in iter_q3_images(Path(args.q3_root)):
        img = open_image_from_bytes(src) if isinstance(src, bytes) else open_image_path(src)
        if img is None:
            continue
        shader = clean_shader_name(rel)
        thumb_name = safe_name(shader) + ".jpg"
        thumb_path = source_thumb_dir / thumb_name
        image_to_thumb(img, args.thumb_size).save(thumb_path, quality=90)
        source_rows.append({"shader": shader, "source": rel, "thumb": norm_path(str(thumb_path))})
    write_jsonl(out / "source_catalog.jsonl", source_rows)
    print(f"[prepare] source textures: {len(source_rows)}")

    print("[prepare] extracting Remix/capture thumbnails...")
    remix_rows = []
    for h, p in iter_remix_images(Path(args.rtx_root), Path(args.txrmap) if args.txrmap else None):
        img = open_image_path(p)
        if img is None:
            continue
        thumb_path = remix_thumb_dir / f"{h}.jpg"
        image_to_thumb(img, args.thumb_size).save(thumb_path, quality=90)
        remix_rows.append({"hash": h, "source": norm_path(str(p)), "thumb": norm_path(str(thumb_path))})
    write_jsonl(out / "remix_catalog.jsonl", remix_rows)
    print(f"[prepare] remix/capture textures: {len(remix_rows)}")

    print("[prepare] building Q3 contact sheets...")
    make_contact_sheets(source_rows, sheet_dir, args.sheet_cols, args.sheet_rows, args.thumb_size)
    print(f"[prepare] sheets: {len(list(sheet_dir.glob('sheet_*.jpg')))}")


def load_font(size: int = 12):
    for name in ("arial.ttf", "C:/Windows/Fonts/arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:
            pass
    return ImageFont.load_default()


def make_contact_sheets(rows: list[dict], sheet_dir: Path, cols: int, rows_per: int, thumb_size: int) -> None:
    font = load_font(11)
    cell_w = thumb_size + 90
    cell_h = thumb_size + 42
    per = cols * rows_per
    for sheet_idx in range(math.ceil(len(rows) / per)):
        chunk = rows[sheet_idx * per:(sheet_idx + 1) * per]
        img = Image.new("RGB", (cols * cell_w, rows_per * cell_h), (34, 34, 34))
        draw = ImageDraw.Draw(img)
        manifest = []
        for i, r in enumerate(chunk):
            x = (i % cols) * cell_w
            y = (i // cols) * cell_h
            thumb = Image.open(r["thumb"]).convert("RGB")
            img.paste(thumb, (x, y))
            label = f"{i}: {r['shader']}"
            # wrap label
            parts = [label[j:j+28] for j in range(0, len(label), 28)][:3]
            draw.text((x + 2, y + thumb_size + 2), "\n".join(parts), fill=(240, 240, 240), font=font)
            manifest.append({"local_index": i, **r})
        img.save(sheet_dir / f"sheet_{sheet_idx:04d}.jpg", quality=88)
        (sheet_dir / f"sheet_{sheet_idx:04d}.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def data_url(path: Path) -> str:
    b = path.read_bytes()
    return "data:image/jpeg;base64," + base64.b64encode(b).decode("ascii")


def lm_call(args, remix_thumb: Path, sheet_path: Path, manifest: list[dict], hash_id: str) -> dict:
    if requests is None:
        raise SystemExit("Install requests first: py -m pip install requests")
    candidate_list = "\n".join([f"{m['local_index']}: {m['shader']}" for m in manifest])
    prompt = f"""
You are matching RTX Remix legacy material thumbnails to original Quake 3 texture paths.
Image 1 is one Remix/capture material thumbnail with hash {hash_id}.
Image 2 is a contact sheet of candidate Quake 3 textures with numbered labels.
Choose the single closest visual match from the contact sheet.
Return ONLY valid JSON with this schema:
{{"hash":"{hash_id}","best_index":number,"best_shader":"path/or/name","confidence":0.0,"notes":"short"}}
If no good match exists on this sheet, set best_index to -1 and confidence below 0.25.
Candidates:\n{candidate_list}
""".strip()
    payload = {
        "model": args.model,
        "temperature": 0.0,
        "max_tokens": 300,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": data_url(remix_thumb)}},
                {"type": "image_url", "image_url": {"url": data_url(sheet_path)}},
            ],
        }],
    }
    r = requests.post(args.lm_url, json=payload, timeout=args.timeout)
    r.raise_for_status()
    text = r.json()["choices"][0]["message"]["content"].strip()
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return {"hash": hash_id, "best_index": -1, "confidence": 0, "raw": text}
    try:
        return json.loads(m.group(0))
    except Exception:
        return {"hash": hash_id, "best_index": -1, "confidence": 0, "raw": text}


def match(args) -> None:
    out = Path(args.out)
    remix_rows = read_jsonl(out / "remix_catalog.jsonl")
    if not remix_rows:
        raise SystemExit("No remix_catalog.jsonl. Run with --prepare first.")
    sheet_dir = out / "contact_sheets"
    sheets = sorted(sheet_dir.glob("sheet_*.jpg"))
    if not sheets:
        raise SystemExit("No contact sheets. Run with --prepare first.")
    done = {r.get("hash") for r in read_jsonl(out / "matches.jsonl")}
    max_items = args.max_items or len(remix_rows)
    with (out / "matches.jsonl").open("a", encoding="utf-8") as f:
        for rr in remix_rows[:max_items]:
            h = rr["hash"]
            if h in done and not args.rematch:
                continue
            remix_thumb = Path(rr["thumb"])
            best = {"hash": h, "best_index": -1, "confidence": 0.0}
            for si, sheet in enumerate(sheets[:args.max_sheets or len(sheets)]):
                manifest = json.loads(sheet.with_suffix(".json").read_text(encoding="utf-8"))
                print(f"[match] {h} sheet {si+1}/{len(sheets)}")
                res = lm_call(args, remix_thumb, sheet, manifest, h)
                res["sheet"] = sheet.name
                try:
                    conf = float(res.get("confidence", 0))
                except Exception:
                    conf = 0
                if conf > float(best.get("confidence", 0)):
                    best = res
                if conf >= args.accept_confidence:
                    break
                time.sleep(args.sleep)
            f.write(json.dumps(best, ensure_ascii=False) + "\n")
            f.flush()
    build_seed(out)


def build_seed(out: Path) -> None:
    rows = read_jsonl(out / "matches.jsonl")
    by_name = {}
    for r in rows:
        try:
            conf = float(r.get("confidence", 0))
        except Exception:
            conf = 0
        shader = r.get("best_shader")
        h = r.get("hash")
        if not shader or not h or conf < 0.45:
            continue
        by_name[clean_shader_name(shader)] = {"hash": h, "shaderName": clean_shader_name(shader), "visualConfidence": conf, "notes": r.get("notes", "")}
    (out / "materials_by_name_seed.json").write_text(json.dumps({"materials_by_name": by_name}, indent=2), encoding="utf-8")
    print(f"[seed] wrote {len(by_name)} matches to {out / 'materials_by_name_seed.json'}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--q3-root", default=r"C:\q3", help="Quake 3 root containing baseq3/pak0.pk3")
    ap.add_argument("--rtx-root", default=r"C:\q3\rtx-remix", help="RTX Remix root containing captures/mods")
    ap.add_argument("--txrmap", default="", help="Optional hash -> captured DDS txrmap.txt")
    ap.add_argument("--out", default="visual_match_out")
    ap.add_argument("--prepare", action="store_true")
    ap.add_argument("--match", action="store_true")
    ap.add_argument("--lm-url", default="http://127.0.0.1:1234/v1/chat/completions")
    ap.add_argument("--model", default="local-model")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--sleep", type=float, default=0.1)
    ap.add_argument("--thumb-size", type=int, default=128)
    ap.add_argument("--sheet-cols", type=int, default=4)
    ap.add_argument("--sheet-rows", type=int, default=5)
    ap.add_argument("--max-items", type=int, default=0)
    ap.add_argument("--max-sheets", type=int, default=0)
    ap.add_argument("--accept-confidence", type=float, default=0.82)
    ap.add_argument("--rematch", action="store_true")
    args = ap.parse_args()
    if args.prepare:
        prepare(args)
    if args.match:
        match(args)
    if not args.prepare and not args.match:
        ap.print_help()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
