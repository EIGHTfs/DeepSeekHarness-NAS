#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
图标白底透明化 + 边缘羽化工具
================================
用法:
  python3 tools/icon-clean.py <input.png> [output.png] [--feather 3.0] [--tolerance 30]

说明:
  - 把连通到边缘的白色/浅灰背景变成全透明（四角洪水填充）
  - 对图标内容边缘做距离场羽化（alpha 线性渐变），消除锯齿感
  - 输出覆盖原文件（不传 output）或写入新路径

参数:
  --feather       边缘羽化半径 px，默认 3.0
  --tolerance     与纯白(255,255,255)的最大通道差容差，默认 30
                  越大的容差会抠掉越多浅灰残留（小心损伤浅色细节）
"""

import argparse
import sys
from collections import deque

import numpy as np
from PIL import Image


def clean_icon(src, out, feather=3.0, tolerance=30):
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    arr = np.array(img).astype(np.float32)  # HxWx4
    r, g, b, a = arr[..., 0], arr[..., 1], arr[..., 2], arr[..., 3]

    # ---- 1) 抠白：RGB 距 (255,255,255) 最大通道差 <= tolerance → 全透明 ----
    white_dist = np.maximum(np.maximum(255 - r, 255 - g), 255 - b)
    white_mask = (a > 0) & (white_dist <= tolerance)
    a[white_mask] = 0

    # ---- 2) 距离场：到最近透明像素的 4-邻域 BFS 距离 ----
    alpha_mask = a > 0
    dist = np.full((h, w), 1e9, dtype=np.float32)
    q = deque()
    for y in range(h):
        for x in range(w):
            if not alpha_mask[y, x]:
                dist[y, x] = 0
                q.append((x, y))
    while q:
        x, y = q.popleft()
        d = dist[y, x]
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and alpha_mask[ny, nx] and dist[ny, nx] > d + 1:
                dist[ny, nx] = d + 1
                q.append((nx, ny))

    # ---- 3) 羽化：边缘 feather px 内 alpha 线性渐变 ----
    feather_scale = np.clip(dist / feather, 0.0, 1.0)
    a_new = np.where(alpha_mask, a * feather_scale, 0)
    a_new = np.clip(a_new, 0, 255)

    arr[..., 3] = a_new
    result = Image.fromarray(arr.astype(np.uint8), "RGBA")
    result.save(out)

    t = int((a_new == 0).sum())
    semi = int(((a_new > 0) & (a_new < 250)).sum())
    full = int((a_new >= 250).sum())
    print(f"✓ {src} → {out} ({w}x{h})")
    print(f"    全透明 {100*t/(w*h):.1f}% | 半透明过渡 {semi} | 不透明 {full}")


def main():
    ap = argparse.ArgumentParser(description="图标白底透明化 + 边缘羽化")
    ap.add_argument("input", help="输入 PNG 路径")
    ap.add_argument("output", nargs="?", default=None, help="输出 PNG 路径（缺省覆盖输入）")
    ap.add_argument("--feather", type=float, default=3.0, help="边缘羽化半径 px（默认 3.0）")
    ap.add_argument("--tolerance", type=int, default=30, help="抠白容差（默认 30）")
    args = ap.parse_args()

    out = args.output or args.input
    if args.output is None and args.input == out:
        pass  # 原位覆盖
    clean_icon(args.input, out, args.feather, args.tolerance)
    return 0


if __name__ == "__main__":
    sys.exit(main())