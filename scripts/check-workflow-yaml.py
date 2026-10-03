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


def check(path):
    out = []
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        return out
    text = open(full, encoding="utf-8", errors="replace").read()
    seen = {}
    for i, line in enumerate(text.split("\n"), 1):
        if "\t" in line[:len(line) - len(line.lstrip())]:
            out.append("%s:%d 缩进含 Tab（YAML 禁止）" % (path, i))
        m = KEYVAL.match(line)
        if not m:
            continue
        indent, key, val = m.group(1), m.group(2), m.group(3)
        # 1) 未加引号的值里含 ": "（块标量 | 或 > 已排除，因为那种行不带值）
        if not (val.startswith('"') or val.startswith("'") or val.startswith("${{") and val.endswith("}}")):
            if ": " in val:
                out.append("%s:%d 未加引号的值里含 ': '（YAML 会当映射分隔符）→ %s"
                           % (path, i, line.strip()[:70]))
    if path.endswith("action.yml"):
        for req in ("name:", "description:", "runs:", "using: composite", "steps:"):
            if req not in text:
                out.append("%s 缺少必需键: %s" % (path, req))
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
