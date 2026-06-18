#!/usr/bin/env python3
"""Bake RTX Remix per-map light authoring (<map>_lights.usda) into compact
JSON the Metal RT pipeline loads at world load.

Usage:
  python3 scripts/rt_lights_from_usda.py \
      --src "$HOME/Downloads/Quake III Arena RTX v0.7/rtx-remix/mods/q3rtx_v07" \
      --out Resources/baseq3/pbr/lights

Output: one <map>.json per <map>_lights.usda:
  { "lights": [ { "type": 0|1|2|3,          # 0=distant 1=sphere 2=disk 3=rect
                  "pos": [x,y,z],            # world units (Q3 == USDA here)
                  "dir": [x,y,z],            # emission dir (distant/spot axis)
                  "color": [r,g,b],          # linear, default (1,1,1)
                  "intensity": f,            # USDA inputs:intensity * 2^exposure
                  "radius": f } ] }          # sphere/disk radius (0 for others)

Parsing is a deliberately small line-based state machine — the Remix light
USDA files are flat `def XxxLight` blocks with scalar attributes; no need
for a USD runtime.
"""
import argparse, json, math, os, re, sys

LIGHT_TYPES = {"DistantLight": 0, "SphereLight": 1, "DiskLight": 2,
               "RectLight": 3, "CylinderLight": 1}

DEF_RE = re.compile(r'def\s+(\w+Light)\s+"')
F_RE = {
    "intensity": re.compile(r'inputs:intensity\s*=\s*([-\d.eE]+)'),
    "exposure": re.compile(r'inputs:exposure\s*=\s*([-\d.eE]+)'),
    "radius": re.compile(r'inputs:radius\s*=\s*([-\d.eE]+)'),
    "width": re.compile(r'inputs:width\s*=\s*([-\d.eE]+)'),
    "height": re.compile(r'inputs:height\s*=\s*([-\d.eE]+)'),
    "cone_angle": re.compile(r'inputs:shaping:cone:angle\s*=\s*([-\d.eE]+)'),
}
V3_RE = {
    "color": re.compile(r'inputs:color\s*=\s*\(([^)]+)\)'),
    "rotate": re.compile(r'xformOp:rotateXYZ\s*=\s*\(([^)]+)\)'),
    "translate": re.compile(r'xformOp:translate\s*=\s*\(([^)]+)\)'),
}


def v3(s):
    return [float(x) for x in s.split(",")]


def rot_xyz_dir(rx, ry, rz):
    """Direction of local -Z after USD rotateXYZ (degrees, applied X,Y,Z)."""
    rx, ry, rz = (math.radians(a) for a in (rx, ry, rz))
    def mx(a):
        c, s = math.cos(a), math.sin(a)
        return [[1, 0, 0], [0, c, -s], [0, s, c]]
    def my(a):
        c, s = math.cos(a), math.sin(a)
        return [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    def mz(a):
        c, s = math.cos(a), math.sin(a)
        return [[c, -s, 0], [s, c, 0], [0, 0, 1]]
    def mul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
                for i in range(3)]
    r = mul(mz(rz), mul(my(ry), mx(rx)))
    v = [0.0, 0.0, -1.0]
    return [sum(r[i][k] * v[k] for k in range(3)) for i in range(3)]


def parse(path):
    lights, cur, depth = [], None, 0
    for line in open(path, encoding="utf-8", errors="replace"):
        m = DEF_RE.search(line)
        if m:
            if cur:
                lights.append(cur)
            cur = {"type": LIGHT_TYPES.get(m.group(1), 1), "intensity": 1.0,
                   "exposure": 0.0, "radius": 0.0, "color": [1, 1, 1],
                   "pos": [0, 0, 0], "dir": [0, 0, -1], "cone_angle": 180.0}
            continue
        if cur is None:
            continue
        for key, rx in F_RE.items():
            m = rx.search(line)
            if m:
                cur[key] = float(m.group(1))
        for key, rx in V3_RE.items():
            m = rx.search(line)
            if m:
                vals = v3(m.group(1))
                if key == "color":
                    cur["color"] = vals
                elif key == "translate":
                    cur["pos"] = vals
                elif key == "rotate":
                    cur["dir"] = rot_xyz_dir(*vals)
    if cur:
        lights.append(cur)
    out = []
    for l in lights:
        radius = l.get("radius", 0.0)
        if l["type"] == 3:  # rect: approximate as disk of equivalent area
            w, h = l.get("width", 10.0), l.get("height", 10.0)
            radius = math.sqrt(max(w * h, 1.0) / math.pi)
        out.append({
            "type": l["type"],
            "pos": [round(v, 2) for v in l["pos"]],
            "dir": [round(v, 4) for v in l["dir"]],
            "color": [round(v, 4) for v in l["color"]],
            "intensity": l["intensity"] * (2.0 ** l.get("exposure", 0.0)),
            "radius": round(radius, 2),
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    total = 0
    for f in sorted(os.listdir(args.src)):
        if not f.endswith("_lights.usda"):
            continue
        mapname = f[: -len("_lights.usda")]
        lights = parse(os.path.join(args.src, f))
        with open(os.path.join(args.out, mapname + ".json"), "w") as fh:
            json.dump({"lights": lights}, fh, separators=(",", ":"))
        print(f"{mapname}: {len(lights)} lights")
        total += len(lights)
    print(f"total {total}")


if __name__ == "__main__":
    sys.exit(main())
