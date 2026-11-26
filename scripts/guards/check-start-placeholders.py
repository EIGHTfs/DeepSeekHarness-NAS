#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-start-placeholders.py — 模板里的 `__占位符__` 必须有注入点。

为什么需要：
  start.sh 的逻辑母版（build/pkgsrc/start.sh.example）里，端口/包名/品牌等一律写成
  `__X__` 占位符，由 gen_start_sh() 在打包期替换。若模板新增了占位符而忘了加替换，
  产物里就会把 `__X__` 字面漏给用户（或空串），而 bash -n、单元测试、体积门禁全都不报错
  —— 只有真正跑起来才暴露，且往往表现为「端口不对/包名不对」这类难倒查的现象。

判据：
  ① 模板中出现的每个 `__X__` 必须能在注入点找到对应替换（缺 → 失败）；
  ② 代理代码里的运行期全局名（window.__DSH_*__）不是占位符，按白名单排除；
  ③ 注入点里存在、但模板里已不用的键只提示、不算失败（注入点也服务其它文件）。

用法：
  python3 scripts/guards/check-start-placeholders.py [--verbose]
退出码：0 通过；1 存在无注入点的占位符
"""
from __future__ import print_function

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TEMPLATE = os.path.join(ROOT, "build", "pkgsrc", "start.sh.example")
INJECTORS = (
    os.path.join(ROOT, "scripts", "lib", "common.sh"),
    os.path.join(ROOT, "build", "spk", "pack-spk.sh"),
    os.path.join(ROOT, "build", "fpk", "pack-fpk.sh"),
)

# 运行期全局名：出现在代理 JS 里（window.__DSH_TRANSPORT__ 等），不是打包期占位符
RUNTIME_GLOBALS = frozenset(("__DSH_TRANSPORT__", "__DSH_FILE_UPLOAD__"))

PLACEHOLDER = re.compile(r"__[A-Z0-9]+(?:_[A-Z0-9]+)*__")
# 注入写法：sed 的 s|__X__|…| 或 s/__X__/…/
INJECTION = re.compile(r"s[|/]__([A-Z0-9_]+)__[|/]")


def placeholders_in_template():
    with open(TEMPLATE, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    found = {}
    for line_number, line in enumerate(text.split("\n"), 1):
        for match in PLACEHOLDER.finditer(line):
            found.setdefault(match.group(0), line_number)
    return found


def injected_keys():
    keys = {}
    for path in INJECTORS:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, 1):
                for match in INJECTION.finditer(line):
                    keys.setdefault("__%s__" % match.group(1), (os.path.relpath(path, ROOT), line_number))
    return keys


def main():
    verbose = "--verbose" in sys.argv[1:]
    template = placeholders_in_template()
    keys = injected_keys()
    problems = []
    for placeholder in sorted(template):
        if placeholder in RUNTIME_GLOBALS:
            if verbose:
                print("  · 跳过运行期全局名 %s（模板第 %d 行）" % (placeholder, template[placeholder]))
            continue
        if placeholder not in keys:
            problems.append("build/pkgsrc/start.sh.example:%d 的 %s 没有任何注入点（gen_start_sh / 打包器里都找不到替换）"
                            % (template[placeholder], placeholder))
        elif verbose:
            print("  ✓ %-24s ← %s:%d" % (placeholder, keys[placeholder][0], keys[placeholder][1]))

    unused = sorted(set(keys) - set(template) - RUNTIME_GLOBALS)
    if unused:
        print("  · 提示：注入点里有 %d 个键在本模板未使用（可能服务其它文件）：%s"
              % (len(unused), ", ".join(unused)))

    if problems:
        print("✗ 模板占位符与注入点不一致（%d 处）：" % len(problems))
        for item in problems:
            print("   %s" % item)
        print("   修复：在 gen_start_sh()（scripts/lib/common.sh）补一条 sed 替换，或把模板里该占位符改回已有名字")
        return 1
    print("✓ 模板 %d 个占位符全部有注入点（白名单运行期全局名 %d 个）"
          % (len(set(template) - RUNTIME_GLOBALS), len(RUNTIME_GLOBALS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
