#!/bin/bash
#===============================================================================
# prune-target.sh — 纯白名单裁剪（install 前 / build 前 / target 后 三模式，独立可跑）
#===============================================================================
# 【用途】三种模式，都走纯白名单（不在白名单 = 删除）：
#
#  模式 A：install 前（--before-install <BUILD_SRC>）
#    pnpm install **之前** 对源码副本 BUILD_SRC 根 package.json 的 devDependencies
#    应用纯白名单：不在白名单的 devDep 一律删除。
#    效果：install 阶段不再下载被裁 devDeps（vitest/jsdom/mermaid 等巨大），
#    CI runner 磁盘峰值骤降。构建必需工具（typescript/tsx/tsdown/lightningcss 等）
#    已手动追加进白名单 extra，install 时保留，build 不会缺工具。
#
#  模式 B：target 后（默认 <TARGET> [WHITELIST]）
#    对已构建 target 的 .pnpm 目录应用纯白名单裁剪：
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
#   ⚠ native/ 不在裁剪范围：node-addon-system-linux-x64 软链真身，删了启动必挂
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
  python3 - "$BUILD_SRC" "$WHITELIST_FILE" <<'PYEOF' 2>&1 || echo "  ⚠ 裁剪 python 段返回非零（详见上方错误）"
import json, os, re, shutil, sys
build_src, white_file = sys.argv[1], sys.argv[2]
white = json.load(open(white_file, encoding='utf-8'))
pnpm = os.path.join(build_src, 'node_modules', '.pnpm')

# ── 白名单 = 运行时闭包 + 构建工具闭包（2026-10-02）────────────────────────
# 前置裁剪的难点：构建工具（tsx/tsdown/vite-tsconfig-paths…）自身依赖
# esbuild / rollup / vite / postcss / oxc-resolver 等**传递依赖**——这些既不在运行时
# lockfileDeps、也不在 extra 名单里，静态列举必漏（实测漏 esbuild →
# build 报 Cannot find package 'esbuild'）。故改为**沿 .pnpm 依赖软链自动递归**：
# 从 extra 构建工具出发收集整棵依赖闭包，闭包内全部保留。
def pkg_name(pnpm_dir):
    base = os.path.basename(pnpm_dir)
    m = re.match(r'(@[^@]+|[^@]+)@', base)
    return m.group(1).replace('+', '/') if m else base

def pkg_deps(full):
    """列出 .pnpm/<pkg>/node_modules/ 下的依赖包名（沿软链/实体目录）。"""
    nm = os.path.join(full, 'node_modules')
    out = set()
    if not os.path.isdir(nm):
        return out
    for e in os.listdir(nm):
        ep = os.path.join(nm, e)
        if e.startswith('@'):
            try:
                for g in os.listdir(ep):
                    if os.path.exists(os.path.join(ep, g)):
                        out.add(f'{e}/{g}')
            except OSError:
                pass
        elif os.path.exists(ep):
            out.add(e)
    return out

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

# 依赖闭包：name→dirs 映射（裁剪前的完整 .pnpm）→ 从声明集合 BFS
name2dirs = {}
if os.path.isdir(pnpm):
    for d in os.listdir(pnpm):
        full = os.path.join(pnpm, d)
        if os.path.isdir(full) and not os.path.islink(full) and d != 'node_modules':
            name2dirs.setdefault(pkg_name(d), []).append(full)
_seen, _stack = set(), list(whitelist)
while _stack:
    _n = _stack.pop()
    if _n in _seen:
        continue
    _seen.add(_n)
    for _d in name2dirs.get(_n, []):
        for _dep in pkg_deps(_d):
            if _dep not in _seen:
                _stack.append(_dep)
build_closure = _seen
whitelist |= build_closure
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

python3 - "$TARGET" "$WHITELIST_FILE" <<'PYEOF' 2>&1 || echo "  ⚠ 裁剪 python 段返回非零（详见上方错误）"
import json, glob, os, re, shutil, sys
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

def pkg_name(pnpm_dir):
    """.pnpm 目录名 → 包名（js-yaml@4.2.0 → js-yaml；@types+js-yaml@4.0.9 → @types/js-yaml）"""
    base = os.path.basename(pnpm_dir)
    m = re.match(r'(@[^@]+|[^@]+)@', base)
    return m.group(1).replace('+', '/') if m else base

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

print('  ✓ 纯白名单裁剪: 保留 %d 个, 删除 %d 个 .pnpm 目录（白名单共 %d 项）%s'
      % (kept, deleted, len(whitelist),
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
