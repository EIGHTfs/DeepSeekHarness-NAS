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
  4. action.yml 的 inputs: 层级（2026-10-15 实证）：input 名必须 2 空格、属性必须 4 空格；
     缩进错【不会】报 YAML 语法错，而是静默变成上一个 input 的子键 → 下游 input 变空 ✗
     （实测：arch 写成 0 空格 + artifact-name 被吞成其子键 → 上传 artifact 报
       "Provided artifact name input during validation is empty"）
  5. workflow 调 action 时 `with:` 的键必须是该 action 已声明的 input
     （实测：传了未声明的 arch → GitHub 报 "Unexpected input(s) 'arch'"）

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
        # 取「全部前导空白」（空格与 Tab 都算）再判其中有无 Tab。
        # 踩过的两个坑：① 无参 lstrip() 会把 Tab 一起剥掉 → 行首 Tab 永远检测不到；
        #               ② 只 lstrip(" ") 则「空格 + Tab」混排的缩进检测不到。
        indent_prefix = re.match(r"[ \t]*", line).group(0)
        if "\t" in indent_prefix:
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
        out += check_step_indent(path, text.splitlines())
        if path.endswith("action.yml"):
            out += check_action_inputs(path, text.splitlines())
        out += _check_action_keys(path, text)
    return out


INPUT_PROPS = ("description", "required", "default", "deprecationMessage", "type", "options")
KEYVAL_ANY = re.compile(r"^(\s*)([A-Za-z_][\w.\-]*):\s*(.*)$")


def _iter_inputs_block(lines):
    """产出 inputs: 块内的 (行号, 原始行, 缩进, 键名或 None)。块以 0 缩进的新顶层键结束。"""
    start = None
    for i, l in enumerate(lines):
        if re.match(r"^inputs:\s*$", l):
            start = i
            break
    if start is None:
        return
    for i in range(start + 1, len(lines)):
        l = lines[i]
        if l.strip() == "" or l.lstrip().startswith("#"):
            continue
        if re.match(r"^[A-Za-z_]", l):      # 回到 0 缩进的顶层键（runs:/name: …）
            return
        ind = len(l) - len(l.lstrip(" "))
        m = KEYVAL_ANY.match(l)
        yield i + 1, l, ind, (m.group(2) if m else None)


def check_action_inputs(path, lines):
    """action.yml 的 inputs: 层级检查（2026-10-15 实证教训）。

    缩进错不会报 YAML 语法错，而是**静默改变结构**：
      · input 名写成 0 缩进 → 不是 input（GitHub: Unexpected input(s)）
      · 紧随其后的 input 被吞成上一个 input 的子键（4 缩进）→ inputs.<名> 解析为空 →
        下游 `name: ${{ inputs.artifact-name }}` 变成空 → 上传 artifact 直接失败
    故强制：input 名恰好 2 空格；属性恰好 4 空格且必须是已知属性名；每个 input 必须有 description。
    """
    if not path.endswith("action.yml"):
        return []
    out, cur = [], None
    seen = {}
    for ln, raw, ind, key in _iter_inputs_block(lines):
        if ind % 2 != 0:
            out.append("%s:%d 缩进为 %d 空格（必须是 2 的倍数）" % (path, ln, ind))
        if ind == 0:
            out.append("%s:%d `%s:` 位于 0 缩进 —— inputs 下的 input 名必须恰好 2 空格（否则不是合法 input）"
                       % (path, ln, key))
            continue
        if ind == 2:
            if key is None or raw.rstrip().endswith(":") is False and not raw.rstrip().endswith(":"):
                out.append("%s:%d 期望 `  <input名>:` 形式，实际: %s" % (path, ln, raw.strip()[:50]))
            cur = key
            seen.setdefault(key, False)
        elif ind == 4:
            if key not in INPUT_PROPS:
                out.append("%s:%d `%s:` 不是已知 input 属性（%s）—— 很可能上一个 input 少了/错了缩进，"
                           "把它吞成了子键" % (path, ln, key, "/".join(INPUT_PROPS)))
            if key == "description" and cur:
                seen[cur] = True
        elif ind > 4:
            out.append("%s:%d 缩进 %d 空格过深（inputs 层级只有 2/4）" % (path, ln, ind))
    for k, has in seen.items():
        if not has:
            out.append("%s inputs.%s 缺少 description（GitHub 必需）" % (path, k))
    return out


def check_action_calls(path, text, action_inputs):
    """workflow 调 action 时 `with:` 的键必须已声明（2026-10-15 实证：多传 arch 会被 GitHub 拒绝）。"""
    out = []
    lines = text.split("\n")
    cur = None
    for i, l in enumerate(lines):
        # 任何 uses: 都要重置归属：本地 action 记名字，第三方 action 置空
        # （2026-10-15 自查：只在匹配本地 action 时更新 cur → 第三方 action 的 with: 会被
        #   错算到上一个本地 action 头上，产生误报 ✗）
        if re.match(r"^\s*-?\s*uses:\s*\S", l):
            m = re.match(r"^\s*-?\s*uses:\s*\./\.github/actions/([A-Za-z0-9_.\-]+)\s*$", l)
            cur = m.group(1) if m else None
            continue
        if cur and re.match(r"^\s*with:\s*$", l):
            base = len(l) - len(l.lstrip(" "))
            for j in range(i + 1, len(lines)):
                l2 = lines[j]
                if l2.strip() == "" or l2.lstrip().startswith("#"):
                    continue
                ind2 = len(l2) - len(l2.lstrip(" "))
                if ind2 <= base:
                    break
                k = re.match(r"^\s*([A-Za-z_][\w.\-]*):", l2)
                if k and k.group(1) not in action_inputs.get(cur, set()):
                    out.append("%s:%d 向 action `%s` 传了未声明的 input `%s`（已声明: %s）—— GitHub 会报 "
                               "Unexpected input(s)" % (path, j + 1, cur, k.group(1),
                                                        ", ".join(sorted(action_inputs.get(cur, set()))) or "无"))
            cur = None
    return out


def check_step_indent(path, lines):
    """同一文件内所有 `- name:` 步骤的缩进必须一致。

    ★ 2026-10-10 血的教训：给 build-target/action.yml 插"记录缓存命中"步骤时用了 6 空格，
      而既有步骤是 4 空格 → YAML 结构被插坏，GitHub 直接拒绝加载：
        ##[error]Failed to load .../action.yml
        System.ArgumentException: Unexpected type '' encountered while reading 'action manifest root'
      该 run（#99 / #101）连构建都没开始就失败。旧守卫只查已知模式（未装 PyYAML），
      查不出"缩进层级错"，故补此项。
    """
    indents = {}
    for i, l in enumerate(lines, 1):
        m = re.match(r'^(\s*)- name:', l)
        if m:
            indents.setdefault(len(m.group(1)), []).append(i)
    if len(indents) > 1:
        detail = '; '.join('%d 空格: 行 %s' % (k, ','.join(map(str, v[:4]))) for k, v in sorted(indents.items()))
        return ['步骤缩进不一致（%s）—— 同级 - name: 必须同缩进' % detail]
    return []


def main():
    v = []
    # 先收集每个 action 已声明的 input 名（供 workflow 的 with: 校验 ✓）
    action_inputs = {}
    for t in TARGETS:
        if not t.endswith("action.yml"):
            continue
        try:
            txt = open(os.path.join(ROOT, t), encoding="utf-8").read()
        except OSError:
            continue
        name = os.path.basename(os.path.dirname(t))
        keys = set()
        for _ln, _raw, _ind, _k in _iter_inputs_block(txt.split("\n")):
            if _ind == 2 and _k:
                keys.add(_k)
        action_inputs[name] = keys
    for t in TARGETS:
        v += check(t)
        if not t.endswith("action.yml"):
            try:
                v += check_action_calls(t, open(os.path.join(ROOT, t), encoding="utf-8").read(), action_inputs)
            except OSError:
                pass
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
