"""Correlate DXGI format + channel order with hash match. Try mip0 raw,
mip0 BGRA<->RGBA swapped, alpha-forced, for xxh3_64 and xxh64."""
import os, struct, glob
import xxhash

CAP = r"C:\q3\rtx-remix\captures\textures"

DXGI = {28:"R8G8B8A8_UNORM",29:"R8G8B8A8_SRGB",87:"B8G8R8A8_UNORM",
        91:"B8G8R8A8_SRGB",71:"BC1_UNORM",74:"BC3_UNORM",98:"BC7_UNORM",
        72:"BC1_SRGB",77:"BC3_SRGB",99:"BC7_SRGB",61:"R8_UNORM",80:"BC4_UNORM"}

def parse(b):
    fourcc = b[84:88]
    h = struct.unpack_from("<i", b, 12)[0]
    w = struct.unpack_from("<i", b, 16)[0]
    mips = struct.unpack_from("<i", b, 28)[0]
    if fourcc == b'DX10':
        dxgi = struct.unpack_from("<I", b, 128)[0]
        pix_off = 148
    else:
        dxgi = None
        pix_off = 128
    return w, h, mips, dxgi, pix_off

def swap_bgra_rgba(data):
    mv = bytearray(data)
    mv[0::4], mv[2::4] = mv[2::4], mv[0::4]
    return bytes(mv)

def force_alpha(data, val=255):
    mv = bytearray(data)
    for i in range(3, len(mv), 4):
        mv[i] = val
    return bytes(mv)

def variants(mip0):
    yield "raw", mip0
    yield "swap", swap_bgra_rgba(mip0)
    yield "alpha255", force_alpha(mip0)
    yield "swap+alpha255", force_alpha(swap_bgra_rgba(mip0))
    yield "alpha0", force_alpha(mip0, 0)

def hh(data):
    return {"xxh3": xxhash.xxh3_64(data).intdigest(),
            "xxh64": xxhash.xxh64(data, seed=0).intdigest()}

files = sorted(glob.glob(os.path.join(CAP, "*.dds")))[:60]
fmt_total = {}
fmt_hit = {}
combo = {}
for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    target = int(name, 16)
    with open(fp, "rb") as f:
        b = f.read()
    if b[0:4] != b'DDS ':
        continue
    w, h, mips, dxgi, pix_off = parse(b)
    fname = DXGI.get(dxgi, f"DXGI#{dxgi}")
    fmt_total[fname] = fmt_total.get(fname, 0) + 1
    mip0 = b[pix_off:pix_off + w*h*4]
    hit = None
    for vn, data in variants(mip0):
        for hn, hv in hh(data).items():
            if hv == target:
                hit = f"{vn}/{hn}"
                break
        if hit: break
    if hit:
        fmt_hit[fname] = fmt_hit.get(fname, 0) + 1
        combo[hit] = combo.get(hit, 0) + 1

print("format totals:", fmt_total)
print("format hits:  ", fmt_hit)
print("winning combos:", combo)
tot = sum(fmt_total.values()); mat = sum(fmt_hit.values())
print(f"matched {mat}/{tot}")
