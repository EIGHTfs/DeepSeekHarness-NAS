#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-start-placeholders.py — 占位符必须有注入点（按平台分组、配置驱动）。

为什么需要：
  打包模板里端口/包名/品牌等写成 `__X__`，由打包脚本在生成期替换。若新增了占位符却忘了加替换，
  产物会把 `__X__` 字面漏给用户（或空串）——`bash -n`、单测、体积门禁全都不报错，只有真跑起来才暴露，
  且常表现为「端口不对/包名不对」这类难倒查的现象。

模型（关键，别理解成「每组各自全覆盖」）：
  · 一个模板的占位符，由**它流经的所有注入组的并集**共同覆盖。
    例：start.sh.example 既经 gen_start_sh()（common 组）又经 pack-spk.sh（synology 组）处理，
        10 个占位符由两组注入点合并满足，而不是要求每组都替换全部 10 个。
  · 分组只解决两件事：① 声明某注入文件属于哪个平台环节（用于把「未使用的键」标到正确平台下）
    ② 声明某模板出现在哪个平台环节。
  · 全部来自 build/config/placeholder-routes.json，代码里不写死文件清单；路径支持 glob，运行期展开，
    新增平台（如 docker）只加一组。

判据：
  ① 每个启用模板的占位符 ⊆ 该模板流经的所有注入点键的并集，否则失败；
  ② 运行期全局名（window.__DSH_*__ 之类）按 runtimeGlobals 白名单排除；
  ③ 各组注入点里有、但该组模板没用到的键：按组提示（可能服务其它环节），不算失败；
  ④ 没有任何模板的组直接跳过 —— 预留平台（docker）未启用时零噪音。

用法：
  python3 scripts/guards/check-start-placeholders.py [--verbose] [--group <name>]
退出码：0 通过；1 存在无注入点的占位符；2 配置不可用（缺文件/坏 JSON）
"""
from __future__ import print_function

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROUTES_FILE = os.path.join(ROOT, "build", "config", "placeholder-routes.json")

PLACEHOLDER = re.compile(r"__[A-Z0-9]+(?:_[A-Z0-9]+)*__")
# 注入写法：sed 的 s|__X__|…| 或 s/__X__/…/
INJECTION = re.compile(r"s[|/]__([A-Z0-9_]+)__[|/]")


def load_routes():
    if not os.path.isfile(ROUTES_FILE):
        print("✗ 缺少占位符路由表：%s" % os.path.relpath(ROUTES_FILE, ROOT))
        return None
    try:
        with open(ROUTES_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except ValueError as error:
        print("✗ 路由表 JSON 非法：%s" % error)
        return None


def expand(patterns):
    """glob 展开（相对仓库根），排序去重，保证输出稳定。"""
    found = []
    for pattern in patterns or []:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
            if os.path.isfile(path) and path not in found:
                found.append(path)
    return found


def placeholders_in(path):
    """返回 {占位符: 行号}。"""
    found = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            for match in PLACEHOLDER.finditer(line):
                found.setdefault(match.group(0), line_number)
    return found


def injected_keys(path):
    """返回 {占位符: 行号}，来自 sed 的 s|__X__| 写法。"""
    keys = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            for match in INJECTION.finditer(line):
                keys.setdefault("__%s__" % match.group(1), line_number)
    return keys


def main():
    verbose = "--verbose" in sys.argv[1:]
    only_group = ""
    if "--group" in sys.argv[1:]:
        index = sys.argv.index("--group")
        only_group = sys.argv[index + 1] if len(sys.argv) > index + 1 else ""

    routes = load_routes()
    if routes is None:
        return 2
    runtime_globals = set(routes.get("runtimeGlobals") or [])

    # 1) 收集每组：注入点键 + 模板清单
    groups = []
    for entry in routes.get("groups") or []:
        name = entry.get("name") or "(未命名)"
        if only_group and name != only_group:
            continue
        groups.append({
            "name": name,
            "desc": entry.get("desc") or "",
            "templates": expand(entry.get("templates")),
            "injectors": expand(entry.get("injectors")),
            "keys": {},
        })
    if not groups:
        print("· 没有匹配的分组（--group %s）" % only_group)
        return 0

    for group in groups:
        for path in group["injectors"]:
            for item, line_number in injected_keys(path).items():
                group["keys"].setdefault(item, (os.path.relpath(path, ROOT), line_number))

    # 2) 模板 → 流经的组集合（并集覆盖模型）
    template_groups = {}
    for group in groups:
        for path in group["templates"]:
            template_groups.setdefault(path, []).append(group["name"])

    problems = []
    checked_total = 0
    print("── 模板（占位符由流经的所有注入点并集覆盖）")
    for path in sorted(template_groups):
        relative = os.path.relpath(path, ROOT)
        owners = template_groups[path]
        merged_keys = {}
        for group in groups:
            if path in group["templates"]:
                merged_keys.update(group["keys"])
        placeholders = {item: line for item, line in placeholders_in(path).items() if item not in runtime_globals}
        checked_total += len(placeholders)
        missing = sorted(item for item in placeholders if item not in merged_keys)
        print("%s %-34s 占位符 %2d · 可覆盖注入键 %2d · 流经组 %s"
              % ("✗" if missing else "✓", relative, len(placeholders), len(merged_keys), "+".join(owners)))
        if verbose:
            for item in sorted(placeholders):
                source = merged_keys.get(item)
                print("     %-24s %s" % (item, ("← %s:%d" % source) if source else "✗ 无注入点"))
        for item in missing:
            problems.append("%s:%d 的 %s 没有注入点（流经组 %s）"
                            % (relative, placeholders[item], item, "+".join(owners)))

    # 3) 各组未使用的注入键：按平台提示（噪音归位）
    print("── 注入点（按平台分组，未用到的键仅提示）")
    for group in groups:
        if not group["injectors"]:
            print("· %-9s 无注入点（预留分组，跳过）" % group["name"])
            continue
        covered = set()
        for path in group["templates"]:
            covered.update(placeholders_in(path))
        unused = sorted(item for item in group["keys"] if item not in covered and item not in runtime_globals)
        used_count = len(group["keys"]) - len(unused)
        print("%s %-9s 注入文件 %d 个 · 键 %d 个（本组模板用到 %d）%s"
              % ("✓", group["name"], len(group["injectors"]), len(group["keys"]), used_count,
                 "" if not unused else "\n     · 提示（可能服务其它环节）：" + ", ".join(unused)))

    if problems:
        print("\n✗ 占位符与注入点不一致（%d 处）：" % len(problems))
        for item in problems:
            print("   %s" % item)
        print("   修复：在对应模板流经的某一组 injectors 文件里补一条 sed 替换，或把模板里该占位符改回已有名字")
        return 1
    print("\n✓ 全部模板的占位符都有注入点（合计 %d 个；路由表 %s）"
          % (checked_total, os.path.relpath(ROUTES_FILE, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
