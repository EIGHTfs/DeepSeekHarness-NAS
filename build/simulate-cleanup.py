#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build-common.sh 裁剪段模拟器 —— 复现「黑白名单」裁剪逻辑，预览将删除/保护的内容。

用法:
  python3 simulate-cleanup.py <target-root> [--list]

  <target-root>  如 build/spk-build/build-0.1.5/target
  --list         打印完整删除清单

逻辑与 build-common.sh 完全一致（配置驱动，不内嵌）：
  黑名单 build-prune-blacklist.json:
    ① pnpmPlatform  非 linux-x64 平台变体（排除 linux-x64）
    ② pnpmMusl      linux-x64-musl 变体
    ③ pnpmApps      claude-agent-sdk / codex
    ④ devDeps       根 package.json devDependencies（精确匹配 esc@ 前缀）
    ⑤ sourceDirs    源码/文档目录（apps|packages src、docs、benchmarks、python）
  白名单 build-prune-whitelist.json（白大于黑）:
    workspaceRuntimeDeps  动态收集 packages/**/dependencies
    extra                 手工补充

输出:
  - 黑名单候选数 / 白名单保护数 / 实际删除数
  - 被保护的关键运行时依赖（js-yaml/sharp/execa 等）
  - native 保留校验
"""
import json
import os
import re
import sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "build/spk-build/build-0.1.5/target"
LIST_ALL = "--list" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
BLACK_FILE = os.path.join(HERE, "build-prune-blacklist.json")
WHITE_FILE = os.path.join(HERE, "build-prune-whitelist.json")

PNPM = os.path.join(TARGET, "node_modules", ".pnpm")


def pkg_name(pnpm_dir):
    base = os.path.basename(pnpm_dir)
    m = re.match(r"(@[^@]+|[^@]+)@", base)
    return m.group(1).replace("+", "/") if m else base


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def main():
    black = json.load(open(BLACK_FILE, encoding="utf-8"))
    white = json.load(open(WHITE_FILE, encoding="utf-8"))
    print(f"黑名单 : {BLACK_FILE}")
    print(f"白名单 : {WHITE_FILE}")
    print(f"target : {TARGET}")
    print(f".pnpm  : {PNPM}")

    # 白名单集合
    whitelist = set(white.get("extra", []))
    if white.get("workspaceRuntimeDeps"):
        pkgs_root = os.path.join(TARGET, "packages")
        for dirpath, _dirs, files in os.walk(pkgs_root):
            if "package.json" in files:
                try:
                    d = json.load(open(os.path.join(dirpath, "package.json"), encoding="utf-8"))
                    whitelist.update((d.get("dependencies") or {}).keys())
                except Exception:
                    pass
    print(f"白名单 : {len(whitelist)} 个（workspace 运行时依赖 + extra）")

    # 黑名单候选
    candidates = set()
    if os.path.isdir(PNPM):
        all_dirs = [os.path.join(PNPM, d) for d in os.listdir(PNPM)
                    if os.path.isdir(os.path.join(PNPM, d))]
        plat_re = re.compile("|".join(re.escape(p) for p in black.get("pnpmPlatform", [])), re.I)
        candidates.update(d for d in all_dirs
                          if plat_re.search(os.path.basename(d)) and "linux-x64" not in os.path.basename(d))
        musl_re = re.compile("|".join(re.escape(p) for p in black.get("pnpmMusl", [])), re.I)
        candidates.update(d for d in all_dirs if musl_re.search(os.path.basename(d)))
        app_re = re.compile("|".join(re.escape(p) for p in black.get("pnpmApps", [])), re.I)
        candidates.update(d for d in all_dirs if app_re.search(os.path.basename(d)))
        if black.get("devDeps"):
            try:
                root_deps = json.load(open(os.path.join(TARGET, "package.json"), encoding="utf-8")).get("devDependencies") or {}
                for dep in root_deps:
                    esc = dep.replace("/", "+")
                    candidates.update(d for d in all_dirs if os.path.basename(d).startswith(esc + "@"))
            except Exception:
                pass
    print(f"黑名单 : {len(candidates)} 个候选 .pnpm 目录")

    # 白名单过滤（白大于黑）
    protected = sorted({d for d in candidates if pkg_name(d) in whitelist})
    to_delete = sorted(d for d in candidates if pkg_name(d) not in whitelist)
    total_size = sum(dir_size(d) for d in to_delete)
    print(f"\n实际删除: {len(to_delete)} 个（黑名单 {len(candidates)} - 白名单 {len(protected)}）共 {total_size/1024/1024:.1f} MB")

    if protected:
        print(f"\n🛡️  白名单保护 {len(protected)} 个:")
        for d in protected:
            print(f"    保留 {pkg_name(d)}  ← {os.path.basename(d)}")

    # 关键运行时依赖校验
    key_deps = ["js-yaml", "sharp", "execa", "lexical", "mdast-util-from-markdown",
                "mdast-util-gfm", "micromark-extension-gfm", "koffi", "esbuild"]
    print("\n=== 关键运行时依赖校验（应全保留）===")
    for dep in key_deps:
        if dep in whitelist:
            hit = [os.path.basename(d) for d in candidates if pkg_name(d) == dep]
            status = f"白名单保护 ✓（黑名单命中 {len(hit)} 个）" if hit else "白名单内 ✓（黑名单未命中）"
        else:
            hit = [os.path.basename(d) for d in to_delete if pkg_name(d) == dep]
            status = f"⚠ 不在白名单且被删 {len(hit)} 个" if hit else "不在白名单但黑名单未命中"
        print(f"  {dep}: {status}")

    # native 校验
    print("\n=== native 保留校验 ===")
    native = os.path.join(TARGET, "native")
    if os.path.isdir(native) and os.path.isfile(os.path.join(native, "system/packages/linux-x64/package.json")):
        print("  ✓ native/ 存在且 linux-x64 变体完整（node-addon 软链真身）")
    elif os.path.isdir(native):
        print("  ⚠ native/ 存在但缺 linux-x64 变体")
    else:
        print("  ✗ native/ 缺失（node-addon-system-linux-x64 软链真身丢失，DSH 启动必挂）")

    # 源码目录校验（⑤ sourceDirs）
    print("\n=== 源码目录裁剪（⑤ sourceDirs）===")
    for pat in black.get("sourceDirs", []):
        hits = glob_matches(TARGET, pat)
        print(f"  {pat}: 将删 {len(hits)} 个" if hits else f"  {pat}: 无匹配")

    if LIST_ALL:
        print("\n=== 完整删除清单 ===")
        for d in to_delete:
            print(f"  {os.path.basename(d)}")


def glob_matches(target, pat):
    import glob
    return [p for p in glob.glob(os.path.join(target, pat)) if os.path.isdir(p) and not os.path.islink(p)]


if __name__ == "__main__":
    main()
