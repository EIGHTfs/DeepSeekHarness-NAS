#!/usr/bin/env python3
"""check-destructive-ops.py — 破坏性操作守卫（2026-10-03 事故的长期防线）

断言三件事：
  1. 指向敏感路径（@appdata / @appstore / @appconf / @apphome / @apptemp /
     @appshare / /volume[0-9]）的 `rm -rf` **必须**带 `--one-file-system`；
     否则退出非 0（防再次跨挂载点删光用户数据）。
  2. `web-install/` 下**不得**再出现独立的清理实现（只允许薄转发调用
     scripts/clean-dsm-residue.sh）—— 消除"web 端与套件端语义分叉"这一事故根因。
  3. `web-install/` 下不得有**未跟踪**文件（防"本地-only 文件静默丢失/自由漂移"）。

豁免：字符串里的文字（log "rm -rf ..."）与注释不计；`safe_rm_rf` 自身实现允许
      出现 `rm -rf --one-file-system`。

用法：python3 scripts/check-destructive-ops.py [--list]
退出码：0 通过 / 1 违规
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SENSITIVE = re.compile(r"@app(data|store|conf|home|temp|share)\b|/volume[0-9]")
RM = re.compile(r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f|\brm\s+-[a-zA-Z]*f[a-zA-Z]*r")
SAFE_FLAG = "--one-file-system"
SKIP_DIRS = {".git", "node_modules", "build/master-build", "dist", ".trash"}
# 分叉指纹（②用）：web-install 下若出现这些，说明它又自带了一套清理/挂载检测实现
FORK_FN = re.compile(r"^\s*(_?)(safe_rm_rf|has_mount_under)\s*\(\)")
FORK_LIB = re.compile(r"/proc/mounts|findmnt\b")


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


def _check_no_fork(violations):
    """② web-install 不得自定义清理/挂载检测实现（分叉指纹）。

    允许：带 --one-file-system 的 inline rm -rf（如卸载路径）；
    禁止：自己定义 safe_rm_rf / has_mount_under 之类，或自带 /proc/mounts、findmnt 解析
          —— 那意味着与 scripts/clean-dsm-residue.sh 分叉（事故根因）。
    """
    web = os.path.join(ROOT, "web-install")
    if not os.path.isdir(web):
        return
    for f in sorted(os.listdir(web)):
        p = os.path.join(web, f)
        if not os.path.isfile(p) or not f.endswith((".sh", ".py")):
            continue
        try:
            t = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for i, line in enumerate(t.splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            if FORK_FN.search(line) or FORK_LIB.search(line):
                violations.append(
                    "web-install/%s:%d 自定义清理/挂载检测实现（与唯一实现 scripts/clean-dsm-residue.sh 分叉）"
                    % (f, i))
                break


def _check_no_untracked(violations):
    """③ web-install 不得有「该入库却漏了」的文件（防本地-only 文件静默丢失/自由漂移）。

    ⚠ 必须尊重 .gitignore：用 `git ls-files --others --exclude-standard` 拿「未跟踪且未被忽略」
    的文件。早期版本用 os.listdir 对比 tracked 列表，把**有意忽略的日志**（如
    web-install/install-server.log）误报成漏入库 —— 该误报由一次单测导入模块触发日志而暴露。
    """
    web = os.path.join(ROOT, "web-install")
    if not os.path.isdir(web):
        return
    try:
        out = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "web-install"],
                             cwd=ROOT, capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return
        for rel in sorted(x for x in out.stdout.split() if x):
            violations.append("%s 未被 git 跟踪（会静默丢失，请入库；若属有意忽略请写进 .gitignore）" % rel)
    except Exception:
        pass


def main():
    """三项检查各自收集违规，最后统一报告（拆开是为了让失败信息对应到明确的一项）。"""
    violations = []
    listing = []
    _check_one_file_system(violations, listing)
    _check_no_fork(violations)
    _check_no_untracked(violations)

    if "--list" in sys.argv:
        for rel, i, st in listing:
            print("  %-40s %4d  %s" % (rel, i, st))
    if violations:
        print("✗ 破坏性操作守卫失败（%d 项）：" % len(violations))
        for v in violations:
            print("   - " + v)
        print("  说明：敏感路径的 rm -rf 必须带 --one-file-system（事故防线）；")
        print("        web-install/ 只允许薄转发调用 scripts/clean-dsm-residue.sh。")
        return 1
    print("✓ 破坏性操作守卫通过（%d 处敏感路径 rm -rf 均已带 --one-file-system）" % len(listing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
