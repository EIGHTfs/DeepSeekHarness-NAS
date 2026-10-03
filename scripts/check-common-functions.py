#!/usr/bin/env python3
"""check-common-functions.py — 公共函数唯一性守卫

断言：scripts/lib/common.sh 导出的函数，在**全仓库其它 .sh 文件里不得再定义**。

⚠ 必须**剔除 heredoc 生成区段**：打包器会用 heredoc 生成目标机运行时脚本
   （如 fnOS 的 log_msg/load_variables_from_file 空桩），那里出现同名函数是
   **不同作用域**，不是重复 —— 详见 scripts/lib/common.sh 头部的「勿收口清单」。
   剔除后仍重复 = 真分叉，必须改为调用公共库。

用法：python3 scripts/check-common-functions.py [--list]
退出码：0 通过 / 1 违规
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "scripts", "lib", "common.sh")
SKIP_DIRS = {".git", "node_modules", "dist", ".trash"}

# 显式豁免（**同名但语义不同**，非分叉；每项必须写明理由）
EXEMPT = {
    "scripts/diagnose/dsh-plugin-install-fix.sh": {
        "section": "彩色 log 版分隔线（log \"${BLUE}===…${NC}\"），与公共库的纯 echo 版语义不同"},
    "scripts/diagnose/setup-pnpm-store.sh": {
        "section": "彩色 log 版分隔线，同上"},
    "scripts/diagnose/test-pnpm-store-fix.sh": {
        "section": "彩色 log 版分隔线，同上"},
}

FUNC = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def lib_functions():
    out = set()
    for line in open(LIB, encoding="utf-8", errors="replace"):
        m = FUNC.match(line)
        if m:
            out.add(m.group(1))
    return out


def strip_heredocs(text):
    """返回 (去掉 heredoc 内容的文本, 行号偏移不变的占位文本)。"""
    lines = text.splitlines()
    keep = []
    i = 0
    while i < len(lines):
        line = lines[i]
        keep.append(line)
        m = HEREDOC.search(line)
        if m and not line.strip().startswith("#"):
            word = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != word:
                keep.append("")          # 挖空 heredoc 内容（保留行号）
                i += 1
            if i < len(lines):
                keep.append(lines[i])    # 终止符本身保留
        i += 1
    return "\n".join(keep)


def main():
    libs = lib_functions()
    if not libs:
        print("✗ 无法从 %s 解析出公共函数" % LIB)
        return 1
    violations = []
    hits = []
    for base, dirs, files in os.walk(ROOT):
        rel = os.path.relpath(base, ROOT)
        if any(rel == d or rel.startswith(d + os.sep) for d in SKIP_DIRS):
            dirs[:] = []
            continue
        for f in sorted(files):
            if not f.endswith(".sh"):
                continue
            path = os.path.join(rel, f)
            if os.path.abspath(os.path.join(base, f)) == os.path.abspath(LIB):
                continue
            try:
                raw = open(os.path.join(base, f), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            stripped = strip_heredocs(raw)
            for i, line in enumerate(stripped.splitlines(), 1):
                m = FUNC.match(line)
                if m and m.group(1) in libs:
                    if m.group(1) in EXEMPT.get(path.replace(os.sep, "/"), {}):
                        continue
                    violations.append("%s:%d 重复定义公共函数 %s()（应改为调用 scripts/lib/common.sh）"
                                      % (path, i, m.group(1)))
                    hits.append((path, i, m.group(1)))
    if "--list" in sys.argv:
        print("  公共库导出 %d 个函数：" % len(libs))
        for h in hits:
            print("    %s:%d %s()" % h)
    if violations:
        print("✗ 公共函数唯一性守卫失败（%d 项）：" % len(violations))
        for v in violations:
            print("   - " + v)
        print("  提示：heredoc 生成区段已被剔除；此处命中即为真分叉，请改为调用公共库。")
        return 1
    print("✓ 公共函数唯一性守卫通过（公共库 %d 个函数，全仓库无重复定义）" % len(libs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
