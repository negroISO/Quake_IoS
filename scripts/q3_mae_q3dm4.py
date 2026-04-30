#!/usr/bin/env python3
"""Deterministic MAE comparator: q3dm4 Metal capture vs Vulkan ref.

v2 robustness:
- step=2, start=0: dense sampling (vs prior step=5, start=10).
- Reject any offset with < 20 samples (penalize alignment-edge offsets
  where only a few frames overlap).
- Downscale both frames to 320x240 before MAE (stable comparison
  resolution, decouples from drawable jitter).
- Median-of-means across 5 chunks instead of plain mean (outlier-robust).
"""

import cv2
import glob
import numpy as np
from pathlib import Path

REF_DIR = "/Users/targus/Documents/q3metal_workspace/compare_baseline_q3dm4/frames_ref"


def load_frames(dir_path):
    return sorted(glob.glob(str(Path(dir_path) / "*.png")))


def prep(img):
    # downscale to stable size
    return cv2.resize(img, (320, 240), interpolation=cv2.INTER_AREA)


def mae(a, b):
    return float(np.mean(np.abs(a.astype(np.float32) - b.astype(np.float32))))


def score_with_offset(ref, out, offset, step=2, start=0):
    vals = []
    for i in range(start, len(out), step):
        j = i + offset
        if 0 <= j < len(ref):
            a = cv2.imread(ref[j])
            b = cv2.imread(out[i])
            if a is None or b is None:
                continue
            a = prep(a)
            b = prep(b)
            vals.append(mae(a, b))
    if len(vals) < 20:
        return None
    # median-of-means for robustness
    chunks = np.array_split(np.array(vals), 5)
    means = [float(np.mean(c)) for c in chunks if len(c) > 0]
    return float(np.median(means)), len(vals)


def find_best_offset(ref, out, max_off=120):
    best = (1e9, 0, 0)
    for off in range(-max_off, max_off + 1):
        res = score_with_offset(ref, out, off)
        if res is None:
            continue
        m, n = res
        if m < best[0]:
            best = (m, off, n)
    return best


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    args = p.parse_args()

    ref = load_frames(REF_DIR)
    out = load_frames(args.out)
    best_mae, best_off, samples = find_best_offset(ref, out)
    print(f"best_mae={best_mae:.4f} best_offset={best_off} samples={samples} metal_frames={len(out)} ref_frames={len(ref)}")
