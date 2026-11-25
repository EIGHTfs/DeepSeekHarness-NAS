#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-path-references.py — 构建脚本里的**物料路径**必须真实存在。

为什么需要：
  目录重组/文件搬家之后，最容易留下的不是语法错误，而是「脚本还指向旧位置」。
  它不会被 bash -n 抓到，只会在 CI 打包/构建的某一轮里炸一次；而本地挂载若是
  大小写不敏感（CIFS/SMB），甚至本地能跑通、CI 才炸 —— 一轮一轮撞非常低效。

  本守卫把「提交前一次查全」变成机器判据：只校验**仓库内应当存在的物料路径**
  （config/ pkgsrc/ tools/ core/ platform/ spk/ fpk/ scripts/ test/ 与图标），
  运行期目录（master-build、.build、tools/aria2 之类）不在检查范围。

用法：
  python3 scripts/guards/check-path-references.py            # 校验
  python3 scripts/guards/check-path-references.py --verbose   # 逐条列出解析结果

退出码：0 通过；1 存在指向不存在物料的引用
"""
from __future__ import print_function

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 变量前缀 → 解析基准（__SELF__ = 该文件所在目录）
BASES = {
    "$BUILD_ROOT": "build", "${BUILD_ROOT}": "build",
    "$D_ASSETS": "build", "${D_ASSETS}": "build",
    "$SCRIPT_DIR": "__SELF__", "${SCRIPT_DIR}": "__SELF__",
    "$WS": "", "${WS}": "",
}

# 只校验这些「仓库内物料」前缀；其余（master-build / .build / tools/aria2 等）跳过
MATERIAL_PREFIXES = (
    "build/config/", "build/pkgsrc/", "build/tools/", "build/core/",
    "build/platform/", "build/spk/", "build/fpk/",
    "scripts/", "test/", "docs/", "assets/",
    "build/PACKAGE_ICON", "build/build-lib.sh", "build/build-common.sh",
)

REFERENCE = re.compile(r"(\$\{?[A-Z_]+\}?)/([\w./*-]+)")
SKIP_FILES = ("node_modules", "src", ".git", ".trash", "master-build", "staging", "__pycache__", "release")


def iter_sources():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_FILES]
        for name in files:
            if name.endswith((".sh", ".py", ".yml", ".yaml")):
                yield os.path.join(base, name)


def resolve(relative_file, variable, tail):
    base = BASES[variable]
    if base == "__SELF__":
        base = os.path.dirname(relative_file)
    joined = tail if not base else os.path.join(base, tail)
    candidate = os.path.normpath(joined)
    if "*" in candidate:
        candidate = os.path.dirname(candidate.split("*")[0].rstrip("/")) or "."
    return candidate.replace(os.sep, "/")


def main():
    verbose = "--verbose" in sys.argv[1:]
    problems = []
    checked = 0
    for path in iter_sources():
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        try:
            text = io.open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for number, line in enumerate(text.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("//"):
                continue
            for match in REFERENCE.finditer(line):
                variable, tail = match.group(1), match.group(2)
                if variable not in BASES:
                    continue
                candidate = resolve(rel, variable, tail)
                if not candidate.startswith(MATERIAL_PREFIXES):
                    continue
                checked += 1
                if not os.path.exists(os.path.join(ROOT, candidate)):
                    problems.append("%s:%d → %s/%s（解析为 %s，不存在）" % (rel, number, variable, tail, candidate))
                elif verbose:
                    print("  ✓ %s:%d → %s" % (rel, number, candidate))
    if problems:
        print("✗ 物料路径引用指向不存在的文件（%d 处）：" % len(problems))
        for item in problems:
            print("   %s" % item)
        print("   修复：目录重组后把引用改到新位置；本地挂载大小写不敏感，一律按仓库真实大小写写")
        return 1
    print("✓ 物料路径引用全部有效（检查 %d 处，覆盖 config/pkgsrc/tools/core/platform/spk/fpk/scripts/test）" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
