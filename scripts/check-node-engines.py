#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-node-engines.py — 校验随包 node 是否满足官方 package.json 的 engines.node。

为什么需要：
  打进包里的 bin/node 直接取自构建机的 NODE_SRC（CI 里由 setup-node 按 engines 安装，
  本地构建则可能命中 /usr/bin/node 或落后几版的 tools/node-dist）。一旦随包 node 低于
  官方要求，用户装完 DSH 会因引擎版本不符拒绝启动或只打一行警告 —— 从包外完全看不出来。
  所以打包后立刻比对一次：不合规就当场失败，而不是等用户装完才发现。

用法：
  python3 scripts/check-node-engines.py --engines "^24.22.3 || >=26.13.1" --node bin/node
  python3 scripts/check-node-engines.py --engines ">=24.9.0" --node-version v24.22.3

退出码：
  0  满足
  1  不满足
  2  无法判定（取不到版本号，或 ranges 写法不支持）—— 调用方应按「警告」处理，不要当成失败
"""
from __future__ import print_function

import argparse
import os
import re
import subprocess
import sys


def parse_version(text):
    """把 'v24.22.3' / '24.22.3' 解析成 (24, 22, 3)；解析不了返回 None。"""
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def version_of_node_file(path):
    """取 node 版本：优先直接执行；不可执行（noexec 挂载）时退化为扫描二进制里的版本串。"""
    if os.access(path, os.X_OK):
        try:
            out = subprocess.check_output([path, "-v"], stderr=subprocess.STDOUT, timeout=20)
            parsed = parse_version(out.decode("utf-8", "replace"))
            if parsed:
                return parsed, "执行 -v 得到"
        except Exception:
            pass
    try:
        with open(path, "rb") as handle:
            blob = handle.read()
        # 二进制里常带形如 v24.22.3 的版本串；取第一个像样的
        for hit in re.finditer(rb"v(\d+)\.(\d+)\.(\d+)", blob):
            major = int(hit.group(1))
            if 10 <= major <= 99:
                return (major, int(hit.group(2)), int(hit.group(3))), "扫描二进制得到"
    except Exception:
        pass
    return None, "无法取得版本"


def cmp_versions(left, right):
    return (left > right) - (left < right)


def satisfies_single(version, spec):
    """判断单个比较式（如 '^24.22.3'、'>=26.13.1'）是否满足。"""
    spec = spec.strip()
    if not spec:
        return True
    m = re.match(r"^(\^|~|>=|<=|>|<|=)?\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$", spec)
    if not m:
        raise ValueError("不支持的写法：%s" % spec)
    op = m.group(1) or "="
    base = tuple(int(m.group(i)) if m.group(i) else 0 for i in (2, 3, 4))

    if op == "^":
        upper = (base[0] + 1, 0, 0)
        return cmp_versions(version, base) >= 0 and cmp_versions(version, upper) < 0
    if op == "~":
        upper = (base[0], base[1] + 1, 0)
        return cmp_versions(version, base) >= 0 and cmp_versions(version, upper) < 0
    if op == ">=":
        return cmp_versions(version, base) >= 0
    if op == ">":
        return cmp_versions(version, base) > 0
    if op == "<=":
        return cmp_versions(version, base) <= 0
    if op == "<":
        return cmp_versions(version, base) < 0
    return cmp_versions(version, base) == 0


def satisfies(version, ranges):
    """'^24.22.3 || >=26.13.1' → 任一备选满足即可；备选内空格分隔视为 AND。"""
    for alternative in ranges.split("||"):
        parts = [p for p in alternative.strip().split() if p]
        if not parts:
            continue
        if all(satisfies_single(version, p) for p in parts):
            return True
    return False


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--engines", required=True, help="官方 engines.node 原文，如 '^24.22.3 || >=26.13.1'")
    ap.add_argument("--node", default="", help="node 可执行文件路径（优先用它取版本）")
    ap.add_argument("--node-version", default="", help="直接给版本号（无法执行 node 时用）")
    args = ap.parse_args()

    if args.node_version:
        version, how = parse_version(args.node_version), "参数给定"
    elif args.node:
        version, how = version_of_node_file(args.node)
    else:
        print("✗ 需要 --node 或 --node-version 之一", file=sys.stderr)
        return 2

    if version is None:
        print("✗ 无法判定：%s（目标 %s）" % (how, args.node or args.node_version), file=sys.stderr)
        return 2

    shown = "v%d.%d.%d" % version
    try:
        ok = satisfies(version, args.engines)
    except ValueError as exc:
        print("✗ 无法判定：%s" % exc, file=sys.stderr)
        return 2

    if ok:
        print("✓ 随包 node %s 满足官方 engines.node（%s）[%s]" % (shown, args.engines, how))
        return 0
    print("✗ 随包 node %s 不满足官方 engines.node（%s）[%s]" % (shown, args.engines, how), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
