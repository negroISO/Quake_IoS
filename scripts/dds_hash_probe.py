"""Probe whether the RTX Remix capture-DDS filename hash can be reproduced
by hashing the DDS's own stored bytes. If yes, the hash algorithm + input
domain is identified and we can map any texture -> RTX hash."""
import os, struct, glob
import xxhash

CAP = r"C:\q3\rtx-remix\captures\textures"

def dds_info(b):
    # standard header 128 bytes; DX10 adds 20 -> pixel data at 148
    fourcc = b[84:88]
    h = struct.unpack_from("<i", b, 12)[0]
    w = struct.unpack_from("<i", b, 16)[0]
    mips = struct.unpack_from("<i", b, 28)[0]
    pix_off = 148 if fourcc == b'DX10' else 128
    return w, h, mips, fourcc, pix_off

def ranges(b, w, h, pix_off):
    mip0 = w * h * 4
    out = {}
    out["whole_file"] = b
    out["from128_eof"] = b[128:]
    out["from148_eof"] = b[148:]
    out[f"mip0@{pix_off}"] = b[pix_off:pix_off + mip0]
    out["allmips@pixoff"] = b[pix_off:]
    # bottom mip (1x1) is last 4 bytes
    out["bottom_mip_4"] = b[-4:]
    # header-only variants sometimes folded in; skip
    return out

def hashes(data):
    return {
        "xxh64_s0": xxhash.xxh64(data, seed=0).intdigest(),
        "xxh64_s0_swap": int.from_bytes(xxhash.xxh64(data, seed=0).digest(), "little"),
        "xxh3_64": xxhash.xxh3_64(data).intdigest(),
        "xxh3_64_swap": int.from_bytes(xxhash.xxh3_64(data).digest(), "little"),
    }

files = sorted(glob.glob(os.path.join(CAP, "*.dds")))[:12]
print(f"probing {len(files)} capture DDS files\n")
any_hit = False
fmt_summary = {}
for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    target = int(name, 16)
    with open(fp, "rb") as f:
        b = f.read()
    if b[0:4] != b'DDS ':
        print(f"{name}: not DDS"); continue
    w, h, mips, fourcc, pix_off = dds_info(b)
    fmt_summary[fourcc] = fmt_summary.get(fourcc, 0) + 1
    hit_here = []
    for rname, data in ranges(b, w, h, pix_off).items():
        for hname, hv in hashes(data).items():
            if hv == target:
                hit_here.append(f"{rname} / {hname}")
                any_hit = True
    status = ("  *** HIT: " + "; ".join(hit_here)) if hit_here else ""
    print(f"{name}  {w}x{h} mips={mips} {fourcc.decode(errors='replace')} size={len(b)}{status}")

print(f"\nformat counts: {fmt_summary}")
print("RESULT:", "HASH REPRODUCED" if any_hit else "no range/algo reproduced the filename hash")
