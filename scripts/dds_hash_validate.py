"""Validate the cracked rule over ALL capture DDS:
   RTX_hash = XXH3_64( mip0 reinterpreted as BGRA ).
Always swap R<->B; for R==B pixels this is identity so it must match all."""
import os, struct, glob
import xxhash

CAP = r"C:\q3\rtx-remix\captures\textures"

def parse(b):
    fourcc = b[84:88]
    h = struct.unpack_from("<i", b, 12)[0]
    w = struct.unpack_from("<i", b, 16)[0]
    mips = struct.unpack_from("<i", b, 28)[0]
    if fourcc == b'DX10':
        dxgi = struct.unpack_from("<I", b, 128)[0]; pix_off = 148
    else:
        dxgi = None; pix_off = 128
    return w, h, mips, dxgi, pix_off

def rtx_hash(mip0_rgba):
    mv = bytearray(mip0_rgba)
    mv[0::4], mv[2::4] = mv[2::4], mv[0::4]   # RGBA -> BGRA
    return xxhash.xxh3_64(bytes(mv)).intdigest()

files = sorted(glob.glob(os.path.join(CAP, "*.dds")))
ok = bad = skip = 0
bad_examples = []
fmt_counts = {}
for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    try:
        target = int(name, 16)
    except ValueError:
        skip += 1; continue
    with open(fp, "rb") as f:
        b = f.read()
    if b[0:4] != b'DDS ':
        skip += 1; continue
    w, h, mips, dxgi, pix_off = parse(b)
    fmt_counts[dxgi] = fmt_counts.get(dxgi, 0) + 1
    mip0 = b[pix_off:pix_off + w*h*4]
    if len(mip0) != w*h*4:
        skip += 1; continue
    if rtx_hash(mip0) == target:
        ok += 1
    else:
        bad += 1
        if len(bad_examples) < 10:
            bad_examples.append(f"{name} {w}x{h} dxgi={dxgi}")

print(f"total files: {len(files)}")
print(f"MATCH: {ok}")
print(f"MISS:  {bad}")
print(f"skipped (non-hash name / non-RGBA / size): {skip}")
print(f"dxgi format counts: {fmt_counts}")
if bad_examples:
    print("miss examples:")
    for e in bad_examples:
        print("  " + e)
print(f"\naccuracy on RGBA mip0 set: {ok}/{ok+bad} = {100*ok/(ok+bad):.2f}%" if (ok+bad) else "n/a")
