#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prune-target.sh 纯白名单裁剪模拟器 —— 预览将保留/删除的内容（不实际删除）。

用法:
  python3 simulate-cleanup.py <target-root> [--list]

  <target-root>  如 build/master-build/build-0.1.5/target
  --list         打印完整删除清单

逻辑与 prune-target.sh 模式 B（target 后裁剪）完全一致（纯白名单，无黑名单）:
  白名单 = lockfileDeps（build-prune-whitelist.json 自动生成的运行时依赖）
         + workspaceRuntimeDeps（动态收集 packages/**/dependencies）
  force_exclude = {@openai/codex, claude-agent-sdk, @anthropic-ai/claude, sharp-libvips-musl}
    —— 即使在白名单里也强制删除（体积大 / disabled preset / 非目标平台）
  .pnpm 里 name 不在白名单（或在 force_exclude）的一律删；在白名单的保留。
  sourceDirs 硬编码裁剪列表（native/ 保留：node-addon 软链真身，删了启动必挂）

输出:
  - 保留/删除计数 + 预计释放空间
  - 关键运行时依赖校验（js-yaml/sharp/execa 等应全保留）
  - native 保留校验
"""
import json
import os
import re
import sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "build/master-build/build-0.1.5/target"
LIST_ALL = "--list" in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
WHITE_FILE = os.path.join(HERE, "build-prune-whitelist.json")

PNPM = os.path.join(TARGET, "node_modules", ".pnpm")

# force_exclude：与 prune-target.sh 保持一致（即使在白名单也删）
FORCE_EXCLUDE = {
    "@openai/codex",
    "claude-agent-sdk",
    "@anthropic-ai/claude",
    "@img/sharp-libvips-linuxmusl-x64",
}


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


def glob_matches(target, pat):
    import glob
    return [p for p in glob.glob(os.path.join(target, pat)) if os.path.isdir(p) and not os.path.islink(p)]


def main():
    white = json.load(open(WHITE_FILE, encoding="utf-8"))
    print(f"白名单 : {WHITE_FILE}")
    print(f"target : {TARGET}")
    print(f".pnpm  : {PNPM}")

    # 白名单集合（纯白名单模式：只用 lockfileDeps + workspaceRuntimeDeps，不用 extra）
    whitelist = set(white.get("lockfileDeps", []))
    if white.get("workspaceRuntimeDeps"):
        pkgs_root = os.path.join(TARGET, "packages")
        for dirpath, _dirs, files in os.walk(pkgs_root):
            if "package.json" in files:
                try:
                    d = json.load(open(os.path.join(dirpath, "package.json"), encoding="utf-8"))
                    whitelist.update((d.get("dependencies") or {}).keys())
                except Exception:
                    pass
    print(f"白名单 : {len(whitelist)} 个（lockfileDeps + workspaceRuntimeDeps，不含 extra）")

    # 纯白名单裁剪决策：不在白名单（或在 force_exclude）→ 删
    kept, deleted = [], []
    if os.path.isdir(PNPM):
        for d in sorted(os.listdir(PNPM)):
            full = os.path.join(PNPM, d)
            if not os.path.isdir(full):
                continue
            name = pkg_name(full)
            if name in whitelist and name not in FORCE_EXCLUDE:
                kept.append(full)
            else:
                deleted.append(full)

    del_total = sum(dir_size(d) for d in deleted)
    print(f"\n纯白名单: 保留 {len(kept)} 个 / 删除 {len(deleted)} 个（预计释放 {del_total/1024/1024:.1f} MB）")

    forced = sorted(d for d in deleted if pkg_name(d) in FORCE_EXCLUDE)
    if forced:
        print(f"\n💥 force_exclude 硬删 {len(forced)} 个（即使在白名单）:")
        for d in forced:
            print(f"    删除 {pkg_name(d)}  ← {os.path.basename(d)}")

    # 关键运行时依赖校验（应全保留）
    key_deps = ["js-yaml", "sharp", "execa", "lexical", "mdast-util-from-markdown",
                "mdast-util-gfm", "micromark-extension-gfm", "koffi", "esbuild"]
    print("\n=== 关键运行时依赖校验（应全保留）===")
    kept_names = {pkg_name(d) for d in kept}
    for dep in key_deps:
        if dep in kept_names:
            print(f"  {dep}: ✅ 保留")
        elif dep in FORCE_EXCLUDE:
            print(f"  {dep}: ⚠ force_exclude 硬删（预期）")
        else:
            print(f"  {dep}: ❌ 不在白名单被删（异常，需查）")

    # native 校验
    print("\n=== native 保留校验 ===")
    native = os.path.join(TARGET, "native")
    if os.path.isdir(native) and os.path.isfile(os.path.join(native, "system/packages/linux-x64/package.json")):
        print("  ✓ native/ 存在且 linux-x64 变体完整（node-addon 软链真身）")
    elif os.path.isdir(native):
        print("  ⚠ native/ 存在但缺 linux-x64 变体")
    else:
        print("  ✗ native/ 缺失（node-addon-system-linux-x64 软链真身丢失，DSH 启动必挂）")

    # sourceDirs 硬编码列表（与 prune-target.sh 一致；native/ 永远保留）
    print("\n=== 源码目录裁剪（sourceDirs 硬编码，native 保留）===")
    source_dirs = ['packages/*/src', 'packages/*/docs', 'packages/*/benchmark*',
                   'apps/*/src', 'apps/*/docs', 'apps/*/__tests__', 'apps/*/__test__',
                   '**/__tests__', '**/__test__', '**/*.test.*', '**/*.spec.*',
                   'benchmarks', '.github', '.claude', '.agents', 'website']
    for pat in source_dirs:
        hits = glob_matches(TARGET, pat)
        print(f"  {pat}: 将删 {len(hits)} 个" if hits else f"  {pat}: 无匹配")

    if LIST_ALL:
        print("\n=== 完整删除清单 ===")
        for d in deleted:
            print(f"  {os.path.basename(d)}")


if __name__ == "__main__":
    main()