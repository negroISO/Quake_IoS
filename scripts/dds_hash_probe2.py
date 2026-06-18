"""For each capture DDS, find which mip level (and hash fn) reproduces the
filename hash. Reveals the RTX Remix texture-hash rule."""
import os, struct, glob
import xxhash

CAP = r"C:\q3\rtx-remix\captures\textures"

def parse(b):
    fourcc = b[84:88]
    h = struct.unpack_from("<i", b, 12)[0]
    w = struct.unpack_from("<i", b, 16)[0]
    mips = struct.unpack_from("<i", b, 28)[0]
    pix_off = 148 if fourcc == b'DX10' else 128
    return w, h, mips, fourcc, pix_off

def mip_ranges(b, w, h, mips, pix_off):
    """Yield (mip_index, mw, mh, data) for each stored mip, RGBA8 assumed."""
    off = pix_off
    cw, ch = w, h
    for i in range(mips):
        size = cw * ch * 4
        yield i, cw, ch, b[off:off+size]
        off += size
        cw = max(1, cw // 2)
        ch = max(1, ch // 2)

def hh(data):
    return {
        "xxh3_64": xxhash.xxh3_64(data).intdigest(),
        "xxh64_s0": xxhash.xxh64(data, seed=0).intdigest(),
    }

files = sorted(glob.glob(os.path.join(CAP, "*.dds")))[:24]
rule_hits = {}
for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    target = int(name, 16)
    with open(fp, "rb") as f:
        b = f.read()
    if b[0:4] != b'DDS ':
        continue
    w, h, mips, fourcc, pix_off = parse(b)
    found = None
    for i, mw, mh, data in mip_ranges(b, w, h, mips, pix_off):
        for hn, hv in hh(data).items():
            if hv == target:
                found = f"mip{i}({mw}x{mh})/{hn}"
                rule_hits[found] = rule_hits.get(found, 0) + 1
                break
        if found:
            break
    print(f"{name} {w}x{h} mips={mips} -> {found or 'NO MATCH'}")

print("\nrule frequency:")
for k, v in sorted(rule_hits.items(), key=lambda kv: -kv[1]):
    print(f"  {k}: {v}")
total = len(files)
matched = sum(rule_hits.values())
print(f"\nmatched {matched}/{total}")
