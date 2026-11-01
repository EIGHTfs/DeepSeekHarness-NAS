#!/usr/bin/env python3
"""check-destructive-ops.py — 破坏性操作守卫（2026-10-03 事故的长期防线）

断言一件事：
  指向敏感路径（@appdata / @appstore / @appconf / @apphome / @apptemp /
  @appshare / /volume[0-9]）的 `rm -rf` **必须**带 `--one-file-system`；
  否则退出非 0（防再次跨挂载点删光用户数据）。

豁免：字符串里的文字（log "rm -rf ..."）与注释不计；`safe_rm_rf` 自身实现允许
      出现 `rm -rf --one-file-system`。

用法：python3 scripts/check-destructive-ops.py [--list]
退出码：0 通过 / 1 违规
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SENSITIVE = re.compile(r"@app(data|store|conf|home|temp|share)\b|/volume[0-9]")
RM = re.compile(r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f|\brm\s+-[a-zA-Z]*f[a-zA-Z]*r")
SAFE_FLAG = "--one-file-system"
SKIP_DIRS = {".git", "node_modules", "build/master-build", "dist", ".trash"}


def scan_files():
    out = []
    for base, dirs, files in os.walk(ROOT):
        rel = os.path.relpath(base, ROOT)
        if any(rel == d or rel.startswith(d + os.sep) for d in SKIP_DIRS):
            dirs[:] = []
            continue
        for f in files:
            if f.endswith((".sh", ".py", ".yml", ".yaml")):
                out.append(os.path.join(rel, f))
    return sorted(out)


def _check_one_file_system(violations, listing):
    """① 敏感路径的 rm -rf 必须带 --one-file-system。

    为什么是这条：历史上对 @appdata/<PKG> 的递归删除会**跨过挂载点**继续往下删
    （本机 @appdata/<PKG>/<版本>/工作区 正是工作区挂载点，源端数据不可恢复）。
    --one-file-system 是阻止跨设备递归的那一道保险。
    注意：本函数注释里刻意不写出完整的危险命令字面量 —— 本守卫会扫描自己，
    带反引号的示例行会被判为真实调用（见下方字符串豁免规则）。

    不视为真实调用的情形：整行注释；以及字符串里的文字（如 log 出来的示例命令），
    但含反引号的行除外（命令替换里可能真的在执行）。
    """
    for rel in scan_files():
        try:
            text = open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if not RM.search(line):
                continue
            # 字符串里的文字（log "rm -rf ..."）不算真实调用
            if re.search(r'''["'][^"']*\brm\s+-[a-zA-Z]*r''', line) and "`" not in line:
                continue
            if not SENSITIVE.search(line):
                continue
            if SAFE_FLAG in line:
                listing.append((rel, i, "OK(带 --one-file-system)"))
                continue
            violations.append("%s:%d 敏感路径 rm -rf 缺少 %s：%s" % (rel, i, SAFE_FLAG, stripped[:100]))
            listing.append((rel, i, "违规"))


def main():
    """三项检查各自收集违规，最后统一报告（拆开是为了让失败信息对应到明确的一项）。"""
    violations = []
    listing = []
    _check_one_file_system(violations, listing)

    if "--list" in sys.argv:
        for rel, i, st in listing:
            print("  %-40s %4d  %s" % (rel, i, st))
    if violations:
        print("✗ 破坏性操作守卫失败（%d 项）：" % len(violations))
        for v in violations:
            print("   - " + v)
        print("  说明：敏感路径的 rm -rf 必须带 --one-file-system（事故防线）。")
        return 1
    print("✓ 破坏性操作守卫通过（%d 处敏感路径 rm -rf 均已带 --one-file-system）" % len(listing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
