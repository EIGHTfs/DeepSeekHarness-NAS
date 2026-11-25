#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-platform-boundary.py — 平台边界守卫：平台专有的东西不许回流到公共构建脚本。

为什么需要：
  build/build-common.sh 是「源码 → target」的平台无关公共内核。一旦有人为图方便
  把群晖/飞牛的版本号规则、打包脚本路径、平台约束写回这个文件，它就无法再复用给
  Docker / OpenWrt 等新形态（每次加平台都要改内核，回归面无限大）。

  所以把边界钉成机器判据：
    ① build/build-common.sh 的**代码行**（非注释）里不允许出现平台专有词；
    ② 每个平台适配器必须实现三个钩子并注册自己。

用法：
  python3 scripts/check-platform-boundary.py            # 校验（CI 与本地都用它）
  python3 scripts/check-platform-boundary.py --verbose   # 列出每个文件逐项结果

退出码：0 通过；1 越界
"""
from __future__ import print_function

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 公共内核：只允许平台无关内容
CORE_FILE = os.path.join(ROOT, "build", "build-common.sh")

# 平台专有词（出现在内核的**代码行**里即越界）
PLATFORM_WORDS = re.compile(
    r"\bSPK_[A-Z_]+\b|\bFPK_[A-Z_]+\b|pack-spk|pack-fpk|\bsynology\b|\bsyno\b|\bdsm\b|trim_|\bfnos\b|飞牛|群晖",
    re.IGNORECASE,
)

# 适配器目录与必备钩子
ADAPTER_DIR = os.path.join(ROOT, "build", "platform")
ADAPTERS = ("synology", "fnos")
REQUIRED_HOOKS = ("_derive", "_meta", "_describe")


def code_lines(path):
    """返回 (行号, 文本) —— 只取代码行：跳过空行与注释行（# 开头、以及行内首个 # 之前的内容）。"""
    result = []
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        for index, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            # 行尾注释剔除（简化处理：不解析引号内的 #，本项目内核里没有这种写法）
            code = line.split("#", 1)[0]
            if code.strip():
                result.append((index, code))
    return result


def check_core(verbose=False):
    problems = []
    if not os.path.isfile(CORE_FILE):
        return ["缺少公共内核：%s" % CORE_FILE]
    for line_number, code in code_lines(CORE_FILE):
        matched = PLATFORM_WORDS.search(code)
        if matched:
            problems.append("%s:%d 出现平台专有词 %r" % (
                os.path.relpath(CORE_FILE, ROOT), line_number, matched.group(0)))
    if verbose and not problems:
        print("  ✓ %s 的代码行无平台专有词" % os.path.relpath(CORE_FILE, ROOT))
    return problems


def check_adapters(verbose=False):
    problems = []
    for name in ADAPTERS:
        path = os.path.join(ADAPTER_DIR, "%s.sh" % name)
        if not os.path.isfile(path):
            problems.append("缺少平台适配器：%s" % os.path.relpath(path, ROOT))
            continue
        text = io.open(path, encoding="utf-8", errors="replace").read()
        for hook in REQUIRED_HOOKS:
            if not re.search(r"platform_%s%s\s*\(\)" % (name, hook), text):
                problems.append("%s 缺钩子 platform_%s%s()" % (
                    os.path.relpath(path, ROOT), name, hook))
        if not re.search(r"PLATFORM_ADAPTERS\+?=\(.*\)|PLATFORM_ADAPTERS\+=\(\"%s\"\)" % name, text):
            problems.append("%s 未注册到 PLATFORM_ADAPTERS" % os.path.relpath(path, ROOT))
        if verbose and not problems:
            print("  ✓ %s 三钩子齐备且已注册" % os.path.relpath(path, ROOT))
    return problems


def main():
    verbose = "--verbose" in sys.argv[1:]
    problems = []
    problems += check_core(verbose)
    problems += check_adapters(verbose)

    if problems:
        print("✗ 平台边界被破坏：")
        for item in problems:
            print("   %s" % item)
        print("   修复：平台专有逻辑写进 build/platform/<平台>.sh，公共内核只调适配器接口")
        return 1
    print("✓ 平台边界完好：公共内核无平台专有词，%d 个适配器三钩子齐备" % len(ADAPTERS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
