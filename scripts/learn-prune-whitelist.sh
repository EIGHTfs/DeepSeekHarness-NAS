#!/bin/bash
# 机制说明（三层来源 / 自动学习边界 / 失败症状）见 README「裁剪白名单」(#prune-whitelist)。
#===============================================================================
# learn-prune-whitelist.sh — 自动学习：把「构建真正需要」的包并入裁剪白名单
#===============================================================================
# 【背景】install 前裁剪 devDeps（prune-target.sh --before-install）会把非白名单
#   根 devDeps 剥掉，但官方根 package.json 的构建/安装脚本（scripts/*.ts|*.mjs，
#   postinstall 等）可能 import 这些被剥的包 → install/build 阶段
#   ERR_MODULE_NOT_FOUND / Cannot find package（实测教训：
#   @yao-pkg/pkg 补丁悬空、lefthook postinstall import 失败，都是一轮轮 CI 试出来的）。
#  本脚本把「判定构建需要什么」自动化，不再手动试错补白名单：
#
#  模式 A（静态解析，--scan <SRC>）：
#    扫描官方源码 scripts/ 目录所有 .ts/.mjs/.js 的顶层 import/require 裸包名，
#    与「即将被剥离的根 devDeps（根 devDependencies - 现有白名单）」求交集，
#    交集即构建脚本真实需要的包 → 并入白名单 extra（--apply 才写盘）。
#
#  模式 B（日志反查，--log <FILE>）：
#    从构建/安装日志提取 ERR_MODULE_NOT_FOUND / Cannot find package /
#    Cannot find module 里缺失的包名，若属「将被剥离的根 devDeps」→ 并入白名单。
#
# 【用法】
#   ./scripts/learn-prune-whitelist.sh --scan <官方源码目录> [--apply] [--dry-run]
#   ./scripts/learn-prune-whitelist.sh --log <构建日志文件> [--apply] [--dry-run]
#   （缺省只打印建议；--apply 才写 build/build-prune-whitelist.json；--dry-run 显式预览）
#
# 【白名单文件】build/build-prune-whitelist.json（与 prune-target.sh 同一权威源）
#   extra 字段追加（幂等去重），不覆盖 gen-prune-whitelist.sh 管理的 lockfileDeps
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
WHITELIST_FILE="${WHITELIST_FILE:-$WS/build/build-prune-whitelist.json}"

MODE=""
APPLY=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) MODE="scan"; TARGET="${2:?--scan 需要源码目录}"; shift 2 ;;
    --log)  MODE="log";  TARGET="${2:?--log 需要日志文件}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    *) echo "✗ 未知参数: $1" >&2; exit 1 ;;
  esac
done

[ -n "$MODE" ] || { echo "✗ 需指定 --scan <SRC> 或 --log <FILE>" >&2; exit 1; }
[ -f "$WHITELIST_FILE" ] || { echo "✗ 白名单不存在: $WHITELIST_FILE" >&2; exit 1; }

echo "▶ 白名单: $WHITELIST_FILE（模式 $MODE）"

# 用 python3 做全部解析与合并（正则提取 + 集合运算 + JSON 写盘）
python3 - "$MODE" "$TARGET" "$WHITELIST_FILE" "$APPLY" <<'PYEOF'
import json, os, re, sys

mode, target, wfile, apply_ = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == '1'

data = json.load(open(wfile, encoding='utf-8'))
extra = set(data.get('extra', []))
lock = set(data.get('lockfileDeps', []))
ws_deps = set(data.get('wsRuntimeDepsCache', []))  # 历史缓存（如有）

# 官方源码目录（模式 A 需要）；日志模式无源码时可缺省
src_root = None
if mode == 'scan':
    src_root = target
    root_pkg = os.path.join(src_root, 'package.json')
    if not os.path.isfile(root_pkg):
        sys.exit(f'✗ 源码根 package.json 不存在: {root_pkg}')
    root_dev = set((json.load(open(root_pkg, encoding='utf-8')).get('devDependencies') or {}).keys())
    # ── 扩展③：候选集加上 workspace 各包的 devDependencies（2026-10-03）──
    #   只扩扫描面不扩候选集，workspace 包自己的构建期 devDeps（如 vite）与类型依赖
    #   （如 @types/semver）会被 `learned &= stripped` 过滤掉 → "扫到了却学不进来"。
    import glob as _glob2
    _ws_dev = set()
    for _pj2 in (_glob2.glob(os.path.join(src_root, 'packages', '*', '*', 'package.json'))
                 + _glob2.glob(os.path.join(src_root, 'apps', '*', 'package.json'))):
        try:
            _d2 = json.load(open(_pj2, encoding='utf-8'))
        except Exception:
            continue
        _ws_dev |= set((_d2.get('devDependencies') or {}).keys())
    root_dev |= _ws_dev
else:
    root_dev = set()  # 日志模式：只对出现的裸包去重，交由 --extra-supplied 决定是否属于 devDeps

# 现有白名单全集（决定「将被剥离」的候选）
existing_white = extra | lock | ws_deps

def bare_imports(text):
    """提取 import/require 的裸包名（顶层/任意缩进；跳过相对路径与 node: 内置）"""
    found = set()
    # import ... from 'x'; import 'x'; require('x'); import x = require('x')
    pats = [
        r"""(?:^|[\s;])import\s+[^'"]*?\s+from\s+['"]([^'"]+)['"]""",
        r"""(?:^|[\s;])import\s+['"]([^'"]+)['"]""",
        r"""require\s*\(\s*['"]([^'"]+)['"]\s*\)""",
        r"""import\s*[^'"]*?\s+=\s+require\s*\(\s*['"]([^'"]+)['"]\s*\)""",
    ]
    for p in pats:
        for m in re.finditer(p, text, re.M | re.S):
            mod = m.group(1)
            if mod.startswith('.') or mod.startswith('/') or mod.startswith('node:') \
               or mod.startswith('#') or '\\' in mod:
                continue
            # 去掉子路径（pkg/subpath → pkg）与 @scope/pkg 的 scope 前缀保留
            if mod.startswith('@'):
                parts = mod.split('/')
                found.add('/'.join(parts[:2]))
            else:
                found.add(mod.split('/')[0])
    return found

learned = set()

if mode == 'scan':
    # 扫描面 = 「构建命脉」脚本的入口文件及其相对 import 链：
    #   ① 根 package.json 的 build 链 / postinstall / clean 引用的入口
    #   ② workspace 各包（packages/*/*、apps/*）的 build*/postinstall 入口
    #   刻意**不**扫全部 scripts/：vitest/jsdom 等测试校验脚本会误学进来（正是裁剪要削的巨型包）。
    rp = json.load(open(os.path.join(src_root, 'package.json'), encoding='utf-8'))
    scripts = rp.get('scripts') or {}

    def entry_files(cmd):
        """命令 → 入口脚本文件（tsx x.ts / node x.mjs / node --import tsx x.ts）"""
        files = []
        for tok in cmd.split():
            if tok.endswith(('.ts', '.mjs', '.js', '.cjs')):
                files.append(tok)
        return files

    def is_vital_script(name):
        return name == 'postinstall' or name == 'clean' or 'build' in name

    vital = []
    for name, cmd in scripts.items():
        if is_vital_script(name):
            vital.extend(entry_files(cmd))
    vital = [p.lstrip('./') for p in vital]

    # ② workspace 各包的构建期脚本：包内构建脚本不扫就学不到
    #    （实测 vite 出现在 packages/experimental/inspector/scripts/devtools/vite.ts）
    import glob as _glob
    for _pj in (_glob.glob(os.path.join(src_root, 'packages', '*', '*', 'package.json'))
                + _glob.glob(os.path.join(src_root, 'apps', '*', 'package.json'))):
        try:
            _ps = (json.load(open(_pj, encoding='utf-8')).get('scripts') or {})
        except Exception:
            continue
        _base = os.path.dirname(_pj)
        for _name, _cmd in _ps.items():
            if not is_vital_script(_name):
                continue
            for _f in entry_files(_cmd):
                _ap = os.path.normpath(os.path.join(_base, _f))
                if _ap.startswith(src_root + os.sep):
                    vital.append(os.path.relpath(_ap, src_root))
    vital = sorted(set(vital))

    seen = set()
    queue = list(vital)
    while queue:
        fname = queue.pop(0)
        fpath = os.path.join(src_root, fname)
        if fname in seen or not os.path.isfile(fpath):
            continue
        seen.add(fname)
        try:
            text = open(fpath, encoding='utf-8', errors='replace').read()
        except Exception:
            continue
        learned |= bare_imports(text)
        # 相对 import（./x.ts）→ 加入队列继续解析
        for m in re.finditer(r"""(?:from\s*|import\s*)['"](\.\.?\/[^'"]+)['"]""", text):
            rel = m.group(1)
            joined = os.path.normpath(os.path.join(os.path.dirname(fname), rel))
            queue.append(joined)
    source = f"构建命脉脚本静态解析（{len(vital)} 入口）"

    # ── 候选判定（统一口径）──────────────────────────────────────────────
    #   判据：**构建命脉脚本 import 到、且裁剪前的树里确实存在** → 必须保白名单。
    #   为什么不用"是否被声明为 devDependency"：传递依赖会被漏掉 —— 实测 vite 不被任何包
    #   声明，却是 packages/experimental/inspector/scripts/devtools/vite.ts 的 import；
    #   按"已声明"过滤就学不到 → 裁剪剥掉 → tsc 报 TS2307: Cannot find module 'vite'
    #   （现象像"没装"，实际 .pnpm 实体还在、被删的是顶层解析入口）。
    #   扫描面只含命脉脚本，故"import 到什么就保什么"不会把 vitest/jsdom 测试树学进来。
    import glob as _glob3
    _nm = os.path.join(src_root, 'node_modules')

    def _in_tree(pkg):
        return (os.path.exists(os.path.join(_nm, pkg))
                or bool(_glob3.glob(os.path.join(_nm, '.pnpm', pkg.replace('/', '+') + '@*'))))

    learned = {p for p in learned if _in_tree(p)}

    # 类型专用依赖：@types/* 不被 import，但 tsc 需要（实测 @types/semver → TS7016）。
    #   对每个学到的包派生 @types/<pkg>（scoped: @scope/name → @types/scope__name），
    #   同样要求"树里存在"。
    _derived = set()
    for _p in learned:
        _d = ('@types/' + _p[1:].replace('/', '__')) if (_p.startswith('@') and _p.count('/') == 1) else ('@types/' + _p)
        if _in_tree(_d):
            _derived.add(_d)
    learned |= _derived
elif mode == 'log':
    try:
        text = open(target, encoding='utf-8', errors='replace').read()
    except Exception as e:
        sys.exit(f'✗ 读日志失败: {e}')
    # Cannot find package 'x' / Cannot find module 'x' / Cannot find module "x"
    # （node ERR_MODULE_NOT_FOUND 完整行形如
    #   Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'lefthook' imported from ...
    #   由上面第一条即可命中；不用宽松 pattern 避免误抓 Cannot/packageName 等词）
    for pat in [r"Cannot find package '([^']+)'",
                r"Cannot find module '([^']+)'",
                r"Cannot find module \"([^\"]+)\""]:
        for m in re.finditer(pat, text):
            mod = m.group(1)
            if mod.startswith('.') or mod.startswith('node:'):
                continue
            if mod.startswith('@'):
                parts = mod.split('/')
                learned.add('/'.join(parts[:2]))
            else:
                learned.add(mod.split('/')[0])
    # ── TS7016：缺的是**类型声明**（@types/<pkg>），不是运行时包本身（2026-10-03）──
    #   实测 scripts/release/publish.ts: error TS7016: Could not find a declaration file
    #   for module 'semver' → 要补 @types/semver（semver 本身可能已在 lockfileDeps）。
    for _pat in [r"Could not find a declaration file for module '([^']+)'",
                 r"Could not find a declaration file for module \"([^\"]+)\""]:
        for _m in re.finditer(_pat, text):
            _mod = _m.group(1)
            if _mod.startswith('.') or _mod.startswith('node:'):
                continue
            if _mod.startswith('@') and _mod.count('/') == 1:
                learned.add('@types/' + _mod[1:].replace('/', '__'))
            else:
                learned.add('@types/' + _mod.split('/')[0])
    # 运行时探测（fix-runtime-deps.sh）的缺包行：▶ 第 N 轮缺包: a b c
    #   按用户口径（只允许白名单自动学习），这些**正是白名单该包含**的运行期依赖，
    #   应学进白名单，而不是打包时临时补包（那会让出货超出白名单）。
    for _m in re.finditer(r"第\s*\d+\s*轮缺包[:：]\s*(.+)", text):
        for _tok in _m.group(1).split():
            _tok = _tok.strip()
            if not _tok or _tok.startswith(".") or _tok.startswith("node:"):
                continue
            learned.add(_tok if (_tok.startswith("@") and _tok.count("/") == 1) else _tok.split("/")[0])
    source = f"日志反查 {target}"

learned = {x for x in learned if x}  # 去空
learned -= existing_white           # 已在白名单的跳过

if not learned:
    print("  ✓ 无新包需要并入（全部已在白名单或不属于裁剪候选）")
    sys.exit(0)

print(f"  学习到 {len(learned)} 个构建需要但将被剥掉的包（来源: {source}）:")
for p in sorted(learned):
    print(f"    - {p}")

if apply_:
    new_extra = sorted(extra | learned)
    data['extra'] = new_extra
    if '_autoLearned' not in data:
        data['_autoLearned'] = []
    for p in sorted(learned):
        if p not in data['_autoLearned']:
            data['_autoLearned'].append(p)
    data['_extraNote'] = (data.get('_extraNote', '') +
        "；learn-prune-whitelist.sh 自动并入 " + str(len(learned)) + " 个构建必需包: "
        + ", ".join(sorted(learned)))
    with open(wfile, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"  ✓ 已并入白名单 extra（--apply），当前 extra 共 {len(new_extra)} 项")
else:
    print("  （--dry-run 未写盘；加 --apply 才生效）")
PYEOF