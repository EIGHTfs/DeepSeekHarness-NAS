#!/bin/bash
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
    # 只扫「命脉脚本」：根 package.json scripts 中 build 链 / postinstall / clean 引用的
    # 入口文件（及其一层层相对 import）。绝不扫 scripts/ 全部（vitest/jsdom 等测试校验
    # 脚本会误学进来，正是裁剪要削掉的巨型包）。
    rp = json.load(open(os.path.join(src_root, 'package.json'), encoding='utf-8'))
    scripts = rp.get('scripts') or {}

    def entry_files(cmd):
        """命令 → 入口脚本文件（tsx x.ts / node x.mjs / node --import tsx x.ts）"""
        files = []
        for tok in cmd.split():
            if tok.endswith(('.ts', '.mjs', '.js', '.cjs')):
                files.append(tok)
        return files

    vital = []
    for name, cmd in scripts.items():
        if name == 'postinstall' or name == 'clean' or 'build' in name:
            vital.extend(entry_files(cmd))
    vital = [p.lstrip('./') for p in vital]

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
    source = f"命脉脚本静态解析（{len(vital)} 入口）"
    # 只保留「将被剥离的根 devDeps」→ 这才是真正需要补白名单的
    stripped = root_dev - existing_white
    learned &= stripped
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