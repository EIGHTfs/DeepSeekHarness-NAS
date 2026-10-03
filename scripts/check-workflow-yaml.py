#!/usr/bin/env python3
"""check-workflow-yaml.py — GitHub Actions YAML 结构守卫（无需第三方库）

为什么需要它（2026-10-04 实测教训）：
  actions/*/action.yml 里写了 `run: echo "…命中: ${{ … }}"`（**未加引号的标量里含 ": "**），
  YAML 把 `: ` 当映射分隔符 → GitHub 报
    Mapping values are not allowed in this context
    Failed to load ./.github/actions/build-target/action.yml
  而**这个错误发生在 action 加载阶段**，CI 里排在后面的守卫脚本根本跑不到 →
  必须在**推送前**本地拦下。

检查项：
  1. `key: value` 形式的行，value 未加引号/不是块标量，却包含 ": " → 报错（本次踩的坑）
  2. 缩进里含 Tab → 报错（YAML 禁止）
  3. action.yml 必需键：name / description / runs / using: composite / steps

用法：python3 scripts/check-workflow-yaml.py [--list]
退出码：0 通过 / 1 违规
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = [".github/workflows/build.yml"] + [
    os.path.join(".github/actions", d, "action.yml")
    for d in sorted(os.listdir(os.path.join(ROOT, ".github", "actions")))
    if os.path.isdir(os.path.join(ROOT, ".github", "actions", d))
]
KEYVAL = re.compile(r"^(\s*)(?:-\s+)?([A-Za-z_][\w.\-]*):\s+(\S.*)$")


def _check_scalars(path, text):
    """① 缩进含 Tab；② 未加引号的值里含 ': '。

    为什么是②：`run: echo "…命中: ${{ … }}"` 这种**未加引号的标量里含 ": "**，
    YAML 会把 `: ` 当映射分隔符 → GitHub 报 Mapping values are not allowed，
    而且**错误发生在 action 加载阶段**，CI 里排在后面的守卫根本跑不到，必须在推送前本地拦下。
    块标量（`|` / `>`）的行本身不带值，故不会进入下面的判断。
    """
    out = []
    for i, line in enumerate(text.split("\n"), 1):
        if "\t" in line[:len(line) - len(line.lstrip())]:
            out.append("%s:%d 缩进含 Tab（YAML 禁止）" % (path, i))
        m = KEYVAL.match(line)
        if not m:
            continue
        _, _, val = m.group(1), m.group(2), m.group(3)
        # 已加引号，或整个值就是一个 ${{ }} 表达式时，允许其中出现 ": "
        if not (val.startswith('"') or val.startswith("'") or (val.startswith("${{") and val.endswith("}}"))):
            if ": " in val:
                out.append("%s:%d 未加引号的值里含 ': '（YAML 会当映射分隔符）→ %s"
                           % (path, i, line.strip()[:70]))
    return out


def _check_needs(path, text):
    """③ needs / needs.X.result 引用的 job 必须真实存在。

    实测踩坑：job 重构后 needs.build-spk.result 求值为空 → 状态落到 fail →
    Release 正文被写成「❌ 缺失」。这类"重构后引用悬空"必须在 CI 前拦下。
    """
    out = []
    jobs = set(re.findall(r"^  ([a-z0-9-]+):\s*$", text, re.M)) - {
        "on", "jobs", "env", "permissions", "concurrency"}
    for m in re.finditer(r"needs:\s*\[([^\]]+)\]", text):
        for j in m.group(1).split(","):
            j = j.strip()
            if j and j not in jobs:
                out.append("%s needs 引用了不存在的 job: %s（现有: %s）" % (path, j, sorted(jobs)))
    for m in re.finditer(r"needs\.([a-z0-9-]+)\.result", text):
        if m.group(1) not in jobs:
            out.append("%s needs.%s.result 引用了不存在的 job（会求值为空 → 状态误判 fail）" % (path, m.group(1)))
    return out


def _check_action_keys(path, text):
    """④ 复合 action 的必需键必须齐全（缺 runs/using 会导致 action 无法加载）。"""
    out = []
    for req in ("name:", "description:", "runs:", "using: composite", "steps:"):
        if req not in text:
            out.append("%s 缺少必需键: %s" % (path, req))
    return out


def check(path):
    """按文件类型分派到各子检查，汇总返回。"""
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        return []
    text = open(full, encoding="utf-8", errors="replace").read()
    out = _check_scalars(path, text)
    if path.endswith("workflows/build.yml") or path.endswith("build.yml"):
        out += _check_needs(path, text)
    if path.endswith("action.yml"):
        out += _check_action_keys(path, text)
    return out


def main():
    v = []
    for t in TARGETS:
        v += check(t)
    if "--list" in sys.argv:
        for t in TARGETS:
            print("  检查: " + t)
    if v:
        print("✗ YAML 结构守卫失败（%d 项）：" % len(v))
        for x in v:
            print("   - " + x)
        return 1
    print("✓ YAML 结构守卫通过（%d 个文件：workflow + %d 个 action）"
          % (len(TARGETS), len(TARGETS) - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
