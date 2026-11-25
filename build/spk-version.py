#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spk-version.py — 把官方完整版本串映射成群晖套件能用的纯数字版本。

为什么需要：
  群晖 INFO 的 version 每段只允许数字（官方文档 synology_package__INFO_necessary_fields.md），
  格式约定为 [feature number]-[build number]。而官方 dsh 的版本带预发布后缀
  （0.2.3-alpha.2、0.2.3-rc.1），直接写进 INFO 会被拒。

映射规则（项目约定，业界无标准可对齐，详见 docs/打包规范.md「版本号」）：
  version = <官方三段>-<build>，build = 阶段基数 + 预发布序号 N

    alpha.N    → 1000 + N     0.2.3-alpha.2 → 0.2.3-1002
    beta.N     → 2000 + N     预留
    rc.N       → 3000 + N     0.2.3-rc.1    → 0.2.3-3001
    preview.N  → 4000 + N     预留（将来新阶段放这里）
    无后缀/纯数字后缀 → 9000   0.2.3 → 0.2.3-9000、0.2.3-20260101 → 0.2.3-9000

  好处：build 完全由版本串算出，不依赖计数器 —— 换机器重算结果一致，不会倒退。

用法：
  python3 build/spk-version.py 0.2.3-alpha.2               # → 0.2.3-1002
  python3 build/spk-version.py 0.2.3-alpha.2 --field beta   # → yes
  python3 build/spk-version.py 0.2.3 --field feature        # → 0.2.3
  python3 build/spk-version.py 0.2.3 --field build          # → 9000

退出码：0 成功；2 输入无法映射（未知阶段、序号超界、缺三段版本）
"""
from __future__ import print_function

import argparse
import re
import sys

# 阶段基数：留出整千的间隔，预发布序号上限 999，避免跨段串档
STAGE_BASE = {
    "alpha": 1000,
    "beta": 2000,
    "rc": 3000,
    "preview": 4000,
}
GA_BUILD = 9000
MAX_SEQUENCE = 999


def parse(version_text):
    """返回 (feature, stage, sequence, build)；无法映射时抛 ValueError。"""
    text = (version_text or "").strip()
    m = re.match(r"^v?(\d+\.\d+\.\d+)(?:-(.+))?$", text)
    if not m:
        raise ValueError("版本不是三段数字形式：%r" % version_text)
    feature = m.group(1)
    suffix = (m.group(2) or "").strip()

    if not suffix:
        return feature, "ga", 0, GA_BUILD

    # 纯数字后缀（如日期戳 20260101）视作正式版：同一 feature 下只应有一个正式版
    if suffix.isdigit():
        return feature, "ga", 0, GA_BUILD

    sm = re.match(r"^([A-Za-z]+)[.\-_]?(\d+)$", suffix)
    if not sm:
        raise ValueError("无法识别的预发布后缀：%r（已知阶段：%s；新阶段请先补映射表）"
                         % (suffix, "/".join(sorted(STAGE_BASE))))
    stage = sm.group(1).lower()
    sequence = int(sm.group(2))
    if stage not in STAGE_BASE:
        raise ValueError("未知阶段 %r（已知阶段：%s）" % (stage, "/".join(sorted(STAGE_BASE))))
    if sequence > MAX_SEQUENCE:
        raise ValueError("预发布序号 %d 超过上限 %d" % (sequence, MAX_SEQUENCE))
    return feature, stage, sequence, STAGE_BASE[stage] + sequence


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("version", help="官方完整版本串，如 0.2.3-alpha.2")
    ap.add_argument("--field", default="version",
                    choices=["version", "feature", "build", "stage", "beta"],
                    help="输出哪一项（缺省 version = <feature>-<build>）")
    args = ap.parse_args()

    try:
        feature, stage, _sequence, build = parse(args.version)
    except ValueError as exc:
        print("✗ %s" % exc, file=sys.stderr)
        return 2

    if args.field == "feature":
        print(feature)
    elif args.field == "build":
        print(build)
    elif args.field == "stage":
        print(stage)
    elif args.field == "beta":
        # 预发布在套件中心标成 Beta；正式版标 no
        print("no" if stage == "ga" else "yes")
    else:
        print("%s-%d" % (feature, build))
    return 0


if __name__ == "__main__":
    sys.exit(main())
