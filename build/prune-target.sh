#!/bin/bash
#===============================================================================
# prune-target.sh — 纯白名单裁剪（install 前 / build 前 / target 后 三模式，独立可跑）
#===============================================================================
# 【用途】三种模式，都走纯白名单（不在白名单 = 删除）：
#
#   ┌──────┬────────────────────┬──────────────────────────┬───────────────────────────────┬──────────┐
#   │ 模式 │ 时机               │ 裁什么                   │ 白名单集合                    │ 需闭包?  │
#   ├──────┼────────────────────┼──────────────────────────┼───────────────────────────────┼──────────┤
#   │ A    │ pnpm install 之前  │ 根 package.json 的       │ extra + lockfileDeps          │ 不需要   │
#   │      │ --before-install   │ devDependencies(+ 清     │ + workspaceRuntimeDeps        │ (无 .pnpm│
#   │      │                    │ pnpm-workspace.yaml 的   │                               │  可走)   │
#   │      │                    │ patchedDependencies)     │                               │          │
#   ├──────┼────────────────────┼──────────────────────────┼───────────────────────────────┼──────────┤
#   │ C    │ install 之后、     │ BUILD_SRC/node_modules   │ lockfileDeps + 全部 workspace │ 需要     │
#   │      │ build 之前         │ /.pnpm                   │ 声明(deps+dev+peer+optional)  │ (原有)   │
#   │      │ --node-modules     │ (不裁源码/文档)          │ + extra（构建工具，必需）     │          │
#   ├──────┼────────────────────┼──────────────────────────┼───────────────────────────────┼──────────┤
#   │ B    │ build 之后、       │ TARGET/node_modules/     │ lockfileDeps                  │ 需要     │
#   │      │ 打到 target        │ .pnpm + 源码/文档 +      │ + workspaceRuntimeDeps        │ ← 原本   │
#   │      │ (默认，出货形态)   │ 权限归一 755/644         │ （不含 extra）                │   没有！ │
#   └──────┴────────────────────┴──────────────────────────┴───────────────────────────────┴──────────┘
#
#   关键区别：
#   ① A 只决定「要下载什么」（清单裁剪，省 CI 磁盘峰值）；B/C 决定「装好的树留什么」。
#   ② C 必须带 extra（tsc/tsx/tsdown 等构建工具），否则 build 直接缺工具失败；
#      B 不能带 extra（最终包不需要类型检查/测试工具），只保留运行时。
#   ③ C 不裁源码/文档（build 还要读 src/）；B 才裁源码/文档并归一权限。
#   ④ **只有 B 决定最终 SPK 里有什么** —— 所以只有 B 的闭包缺失会导致出货的包缺依赖
#      （本次故障即此），A/C 的名单差异只会造成构建期或体积问题。
#
#  模式 A：install 前（--before-install <BUILD_SRC>）
#    pnpm install **之前** 对源码副本 BUILD_SRC 根 package.json 的 devDependencies
#    应用纯白名单：不在白名单的 devDep 一律删除。
#    效果：install 阶段不再下载被裁 devDeps（vitest/jsdom/mermaid 等巨大），
#    CI runner 磁盘峰值骤降。构建必需工具（typescript/tsx/tsdown/lightningcss 等）
#    已手动追加进白名单 extra，install 时保留，build 不会缺工具。
#
#  模式 B：target 后（默认 <TARGET> [WHITELIST]）
#    对已构建 target 的 .pnpm 目录应用纯白名单裁剪（**含依赖闭包**，2026-10-03 修）：
#    不在 lockfileDeps + workspaceRuntimeDeps 的一律删除。
#    额外排除 codex/claude（disabled preset，即使在 lockfileDeps 也删）。
#    + sourceDirs 源码/文档裁剪。
#
#  模式 C：install 后、build 前（--node-modules <BUILD_SRC> [WHITELIST]，2026-10-02 新增）
#    对**构建副本** BUILD_SRC/node_modules/.pnpm 应用纯白名单裁剪，使 pnpm build 在
#    精简依赖树上运行——避免「全量 install 8G → 编译 → 末尾才裁」的磁盘/内存峰值。
#    ⚠ 与模式 B 的关键区别：**必须带 extra**（typescript/tsx/tsdown/lightningcss 等
#      构建工具），否则 build 缺工具直接失败。不做源码/文档裁剪（build 还要读 src）。
#
# 【规则】纯白名单：白名单列出的保留，其余全删。无黑名单。
#   白名单 = extra（模式 A/C 用，构建与类型检查包）+ lockfileDeps（自动生成的运行时依赖）
#          + workspaceRuntimeDeps（动态收集 packages/*/package.json dependencies）
#   ⚠ 纯名字白名单必须再做**依赖闭包扩展**（沿 .pnpm 依赖软链 BFS），否则外部包的
#     运行时传递依赖会被误删。公共实现见 build/prune_common.py。
#   ⚠ native/ 不在裁剪范围：node-addon-system-linux-x64 软链真身，删了启动必挂
#
# 【2026-10-03 修复：模式 B 补上依赖闭包】
#   实测缺陷：模式 B 原本没有闭包扩展（模式 C 有），把外部包的传递依赖删光——
#     @deepseek-ai/libreoffice-kit → fontkit          （dsh-office-to-pdf failed to import）
#     got                         → @sindresorhus/is  （dsh-otel failed to import）
#     @modelcontextprotocol/client → @modelcontextprotocol/core
#   两台机器（10.10.10.64 / 10.10.10.193）装的同一 SPK 全部中招。
#   同时把 pkg_name / pkg_deps / expand_closure 抽到 build/prune_common.py：
#   原先 B/C 各自内联、pkg_name 重复定义两份，正是模式 B 漂移掉的机制性原因。
#   ⚠ 以后新增模式请一律 import build/prune_common.py，不要再内联复制。
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHITELIST_FILE="${WHITELIST_FILE:-$SCRIPT_DIR/build-prune-whitelist.json}"

MODE_BEFORE_INSTALL=0
MODE_BEFORE_BUILD=0
if [[ "${1:-}" == "--before-install" ]]; then
  MODE_BEFORE_INSTALL=1
  BUILD_SRC="${2:?用法: $0 --before-install <BUILD_SRC>}"
  [ -d "$BUILD_SRC" ] || { echo "✗ BUILD_SRC 不存在: $BUILD_SRC" >&2; exit 1; }
elif [[ "${1:-}" == "--node-modules" ]]; then
  MODE_BEFORE_BUILD=1
  BUILD_SRC="${2:?用法: $0 --node-modules <BUILD_SRC> [WHITELIST]}"
  WHITELIST_FILE="${3:-$WHITELIST_FILE}"
  [ -d "$BUILD_SRC/node_modules" ] || { echo "✗ BUILD_SRC/node_modules 不存在: $BUILD_SRC" >&2; exit 1; }
else
  TARGET="${1:?用法: $0 <TARGET> [WHITELIST] | --before-install <BUILD_SRC> | --node-modules <BUILD_SRC>}"
  WHITELIST_FILE="${2:-$WHITELIST_FILE}"
  [ -d "$TARGET" ] || { echo "✗ target 不存在: $TARGET" >&2; exit 1; }
fi

# ==============================================================================
# 模式 A：install 前裁剪 devDependencies（纯白名单）
# ==============================================================================
if [ "$MODE_BEFORE_INSTALL" = "1" ]; then
  echo "▶ install 前裁剪 devDeps（纯白名单）: $BUILD_SRC"
  python3 - "$BUILD_SRC" "$WHITELIST_FILE" <<'PYEOF' 2>&1 || echo "  ⚠ 裁剪 python 段返回非零（详见上方错误）"
import json, os, sys
build_src, white_file = sys.argv[1], sys.argv[2]
white = json.load(open(white_file, encoding='utf-8'))

# 白名单集合：extra（类型检查包等） + lockfileDeps + workspaceRuntimeDeps
whitelist = set(white.get('extra', []))
whitelist.update(white.get('lockfileDeps', []))
if white.get('workspaceRuntimeDeps'):
    pkgs_root = os.path.join(build_src, 'packages')
    for dirpath, dirnames, filenames in os.walk(pkgs_root):
        if 'package.json' in filenames:
            try:
                d = json.load(open(os.path.join(dirpath, 'package.json'), encoding='utf-8'))
                whitelist.update((d.get('dependencies') or {}).keys())
            except Exception:
                pass

# 纯白名单：根 devDependencies 不在白名单的一律删除
root_pkg = os.path.join(build_src, 'package.json')
try:
    data = json.load(open(root_pkg, encoding='utf-8'))
    dev = data.get('devDependencies') or {}
    candidates = [k for k in dev if k not in whitelist]
    if candidates:
        for k in candidates:
            dev.pop(k, None)
        data['devDependencies'] = dev
        with open(root_pkg, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"  ✓ 剥离 {len(candidates)} 个非白名单 devDeps: {', '.join(candidates[:8])}{'...' if len(candidates)>8 else ''}")
        # 同步清理 pnpm-workspace.yaml 的 patchedDependencies
        import re as _re
        ws_yaml = os.path.join(build_src, 'pnpm-workspace.yaml')
        if os.path.isfile(ws_yaml):
            try:
                lines = open(ws_yaml, encoding='utf-8').read().splitlines()
                pats = [r"^\s*['\"]?" + _re.escape(k) + r"@[^'\":]*(?:['\"]\s*)?:" for k in candidates]
                out, removed = [], []
                for ln in lines:
                    if any(_re.match(p, ln) for p in pats):
                        removed.append(ln.strip().split(':')[0])
                        continue
                    out.append(ln)
                if removed:
                    open(ws_yaml, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
                    print(f"  ✓ 清理 {len(removed)} 个已剥离 devDeps 的补丁声明: {', '.join(removed)}")
            except Exception as e2:
                print(f"  ⚠ 补丁声明清理失败: {e2}")
    else:
        print("  ✓ 无非白名单 devDeps 需剥离")
except Exception as e:
    print(f"  ⚠ 剥离失败: {e}")
PYEOF
  exit 0
fi

# ==============================================================================
# 模式 C：install 后、build 前裁剪（构建副本 node_modules/.pnpm，纯白名单 + extra）
#   让 build 在精简依赖树上跑；白名单必须含 extra（构建工具），否则 build 缺包。
#   不做源码/文档裁剪（build 需要 src/、tsconfig、脚本等）。
# ==============================================================================
if [ "$MODE_BEFORE_BUILD" = "1" ]; then
  echo "▶ build 前裁剪 node_modules: $BUILD_SRC/node_modules（$(du -sh "$BUILD_SRC/node_modules" 2>/dev/null | cut -f1)）"
  PRUNE_COMMON_DIR="$SCRIPT_DIR" python3 - "$BUILD_SRC" "$WHITELIST_FILE" <<'PYEOF' 2>&1 || echo "  ⚠ 裁剪 python 段返回非零（详见上方错误）"
import json, os, re, shutil, sys
sys.path.insert(0, os.environ['PRUNE_COMMON_DIR'])
from prune_common import pkg_name, pkg_deps, expand_closure   # 公共逻辑，勿再内联复制
build_src, white_file = sys.argv[1], sys.argv[2]
white = json.load(open(white_file, encoding='utf-8'))
pnpm = os.path.join(build_src, 'node_modules', '.pnpm')

# ── 白名单 = 运行时闭包 + 构建工具闭包（2026-10-02）────────────────────────
# 前置裁剪的难点：构建工具（tsx/tsdown/vite-tsconfig-paths…）自身依赖
# esbuild / rollup / vite / postcss / oxc-resolver 等**传递依赖**——这些既不在运行时
# lockfileDeps、也不在 extra 名单里，静态列举必漏（实测漏 esbuild →
# build 报 Cannot find package 'esbuild'）。故改为**沿 .pnpm 依赖软链自动递归**：
# 从白名单出发收集整棵依赖闭包，闭包内全部保留。
# （pkg_name / pkg_deps / expand_closure 已抽到 build/prune_common.py，2026-10-03）

# ── 构建期白名单（2026-10-02 修正）：以「所有 workspace 包声明的依赖」为根 ──
# 教训：只从 extra（构建工具）出发会漏掉**源码构建依赖**——react/react-dom/electron/
# electron-builder 等声明在各 workspace 包的 devDependencies（如 apps/desktop），
# 不在运行时 lockfileDeps 中 → 被裁 → desktop 的 vite 构建报
# "Rollup failed to resolve import react/jsx-runtime"。
# 正确口径：deps + devDeps + peerDeps + optionalDeps（全部 workspace 包 + 根
# package.json）→ 沿 .pnpm 软链求闭包 → 闭包内全部保留。
def _collect_declared(root_dir):
    out = set()
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames[:] = [d for d in dirnames if d != 'node_modules']
        if 'package.json' in filenames:
            try:
                d = json.load(open(os.path.join(dirpath, 'package.json'), encoding='utf-8'))
                for k in ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'):
                    out.update((d.get(k) or {}).keys())
            except Exception:
                pass
    return out

declared = set()
for _sub in ('packages', 'apps', 'vendor', 'native', 'scripts', 'website'):
    _p = os.path.join(build_src, _sub)
    if os.path.isdir(_p):
        declared |= _collect_declared(_p)
try:
    _rp = json.load(open(os.path.join(build_src, 'package.json'), encoding='utf-8'))
    for k in ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'):
        declared.update((_rp.get(k) or {}).keys())
except Exception:
    pass

# 运行时白名单（lockfileDeps）兜底 + 声明集合 + extra（构建工具）
whitelist = set(white.get('lockfileDeps', [])) | declared | set(white.get('extra', []))
if white.get('workspaceRuntimeDeps'):
    pkgs_root = os.path.join(build_src, 'packages')
    for dirpath, dirnames, filenames in os.walk(pkgs_root):
        if 'package.json' in filenames:
            try:
                d = json.load(open(os.path.join(dirpath, 'package.json'), encoding='utf-8'))
                whitelist.update((d.get('dependencies') or {}).keys())
            except Exception:
                pass

# 依赖闭包：从白名单种子沿 .pnpm 软链 BFS（公共实现，见 build/prune_common.py）
whitelist, build_closure = expand_closure(whitelist, pnpm)
declared_n = len(declared)

force_exclude = {'@openai/codex', 'claude-agent-sdk', '@anthropic-ai/claude',
                 '@img/sharp-libvips-linuxmusl-x64'}

deleted = kept = 0
hoist_broken = 0
# ⚠ 特殊目录：.pnpm/node_modules 是 pnpm 的**提升链接目录**（非包目录、目录名不带
#    版本号），按包名逻辑会被误判为"非白名单"而删除 → 破坏依赖提升解析。
#    2026-10-02 修复：显式保留，并清理其中指向已删包的悬空软链。
SPECIAL_DIRS = {'node_modules'}
if os.path.isdir(pnpm):
    for d in sorted(os.listdir(pnpm)):
        full = os.path.join(pnpm, d)
        if not os.path.isdir(full):
            continue
        if d in SPECIAL_DIRS:
            kept += 1
            continue
        name = pkg_name(full)
        if name in whitelist and name not in force_exclude:
            kept += 1
        else:
            shutil.rmtree(full, ignore_errors=True)
            deleted += 1

# 清理 .pnpm/node_modules 内指向已删包的悬空软链（含 @scope/ 一层子目录）
hoist = os.path.join(pnpm, 'node_modules')
if os.path.isdir(hoist):
    for entry in os.listdir(hoist):
        ep = os.path.join(hoist, entry)
        targets = [ep] if os.path.islink(ep) else (
            [os.path.join(ep, g) for g in os.listdir(ep)] if os.path.isdir(ep) and entry.startswith('@') else [])
        for tp in targets:
            if os.path.islink(tp) and not os.path.exists(tp):
                try:
                    os.unlink(tp); hoist_broken += 1
                except OSError:
                    pass
print('  ✓ build 前裁剪: 保留 %d 个, 删除 %d 个 .pnpm 目录'
      '（白名单 %d 项 = 声明依赖 %d + 闭包 %d）%s'
      % (kept, deleted, len(whitelist), declared_n, len(build_closure),
         ('；清理 %d 条悬空提升软链' % hoist_broken) if hoist_broken else ''))
PYEOF
  echo "✓ build 前裁剪完成: $BUILD_SRC/node_modules（$(du -sh "$BUILD_SRC/node_modules" 2>/dev/null | cut -f1)）"
  exit 0
fi

# ==============================================================================
# 模式 B：target 后裁剪（纯白名单）
# ==============================================================================
echo "▶ 裁剪 target: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"

PRUNE_COMMON_DIR="$SCRIPT_DIR" python3 - "$TARGET" "$WHITELIST_FILE" <<'PYEOF' 2>&1 || echo "  ⚠ 裁剪 python 段返回非零（详见上方错误）"
import json, glob, os, re, shutil, sys
sys.path.insert(0, os.environ['PRUNE_COMMON_DIR'])
from prune_common import pkg_name, expand_closure   # 公共逻辑，勿再内联复制
target, white_file = sys.argv[1], sys.argv[2]
white = json.load(open(white_file, encoding='utf-8'))
pnpm = os.path.join(target, 'node_modules', '.pnpm')

# ── 白名单集合（纯白名单模式：只保留这些，其余全删） ──
# 只用运行时依赖（lockfileDeps + workspaceRuntimeDeps），不用 extra
#（extra 里的类型检查包只在模式 A 保护 tsc，不需要进最终 target）
whitelist = set(white.get('lockfileDeps', []))
if white.get('workspaceRuntimeDeps'):
    pkgs_root = os.path.join(target, 'packages')
    for dirpath, dirnames, filenames in os.walk(pkgs_root):
        if 'package.json' in filenames:
            try:
                d = json.load(open(os.path.join(dirpath, 'package.json'), encoding='utf-8'))
                whitelist.update((d.get('dependencies') or {}).keys())
            except Exception:
                pass

# ── 依赖闭包（2026-10-03 修复：模式 B 此前完全没有闭包）────────────────────
# 【症状】纯名字白名单只认「lockfileDeps 里列出的包名」+「workspace 包自己声明的依赖」，
#   而**外部包自己的传递依赖两者都不属于**：
#       @deepseek-ai/libreoffice-kit@0.1.1 → fontkit@2.0.4         （dsh-office-to-pdf 挂）
#       got@14.6.6                         → @sindresorhus/is@^7.0.1（dsh-otel 挂）
#       @modelcontextprotocol/client@2.0.0 → @modelcontextprotocol/core（acp-app 挂）
#   于是它们被无条件删除，而消费者 `got` / `libreoffice-kit` 留下 → 目录里出现
#   悬空软链（这正是本缺陷的指纹）。装完 DSH 启动报 "Cannot find package 'x'",
#   内置插件 failed to import。实测 10.10.10.64 与 10.10.10.193 两台机器安装的
#   同一个 SPK 全部中招（同源构建缺陷，非某台机器偶发）。
# 【为何只漏模式 B】模式 C（build 前）早已有闭包，模式 B（最终 target）只做纯名单
#   匹配 → 模式 C 保住的包在最后一步又被删掉。
# 【修法】调公共 expand_closure，与模式 C 同款（见 build/prune_common.py）。
whitelist, runtime_closure = expand_closure(whitelist, pnpm)

# 强制排除（即使在白名单里也不保留：体积大 / disabled preset / 非目标平台）
force_exclude = {'@openai/codex', 'claude-agent-sdk', '@anthropic-ai/claude',
                 '@img/sharp-libvips-linuxmusl-x64'}

# ── 纯白名单裁剪：.pnpm 里不在白名单的一律删 ──
deleted = 0
kept = 0
hoist_broken = 0
# ⚠ 特殊目录同模式 C：.pnpm/node_modules 是 pnpm 提升链接目录（名不带版本号），
#    必须保留，否则依赖提升解析被破坏（2026-10-02 修复）。
SPECIAL_DIRS = {'node_modules'}
if os.path.isdir(pnpm):
    for d in sorted(os.listdir(pnpm)):
        full = os.path.join(pnpm, d)
        if not os.path.isdir(full):
            continue
        if d in SPECIAL_DIRS:
            kept += 1
            continue
        name = pkg_name(full)
        if name in whitelist and name not in force_exclude:
            kept += 1
        else:
            shutil.rmtree(full, ignore_errors=True)
            deleted += 1

# 清理 .pnpm/node_modules 内指向已删包的悬空软链
hoist = os.path.join(pnpm, 'node_modules')
if os.path.isdir(hoist):
    for entry in os.listdir(hoist):
        ep = os.path.join(hoist, entry)
        targets = [ep] if os.path.islink(ep) else (
            [os.path.join(ep, g) for g in os.listdir(ep)] if os.path.isdir(ep) and entry.startswith('@') else [])
        for tp in targets:
            if os.path.islink(tp) and not os.path.exists(tp):
                try:
                    os.unlink(tp); hoist_broken += 1
                except OSError:
                    pass

print('  ✓ 纯白名单裁剪: 保留 %d 个, 删除 %d 个 .pnpm 目录'
      '（白名单 %d 项 = 名单 %d + 闭包 %d）%s'
      % (kept, deleted, len(whitelist), len(whitelist) - len(runtime_closure), len(runtime_closure),
         ('；清理 %d 条悬空提升软链' % hoist_broken) if hoist_broken else ''))

# 源码/文档裁剪（native/ 保留）
sourceDirs = ['packages/*/src', 'packages/*/docs', 'packages/*/benchmark*',
              'apps/*/src', 'apps/*/docs', 'apps/*/__tests__', 'apps/*/__test__',
              '**/__tests__', '**/__test__', '**/*.test.*', '**/*.spec.*',
              'benchmarks', '.github', '.claude', '.agents', 'website']
for pat in sourceDirs:
    for p in glob.glob(os.path.join(target, pat)):
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p, ignore_errors=True)
for f in ['tsconfig.host.tsbuildinfo', 'tsconfig.client.tsbuildinfo']:
    p = os.path.join(target, f)
    if os.path.isfile(p):
        os.remove(p)
PYEOF
echo "  ✓ 源码/文档裁剪（native 保留；lib/dist 产物保留）"

# 修正权限
find "$TARGET" -type d -exec chmod 755 {} + 2>/dev/null
find "$TARGET" -type f ! -executable -exec chmod 644 {} + 2>/dev/null
find "$TARGET" -type f -executable -exec chmod 755 {} + 2>/dev/null

echo "✓ 裁剪完成: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
