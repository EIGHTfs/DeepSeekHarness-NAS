#!/bin/bash
#===============================================================================
# prune-target.sh — 纯白名单裁剪（install 前 / target 后 双模式，独立可跑）
#===============================================================================
# 【用途】两种模式，都走纯白名单（不在白名单 = 删除）：
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
# 【规则】纯白名单：白名单列出的保留，其余全删。无黑名单。
#   白名单 = extra（模式 A 用，类型检查包）+ lockfileDeps（自动生成的运行时依赖）
#          + workspaceRuntimeDeps（动态收集 packages/*/package.json dependencies）
#   ⚠ native/ 不在裁剪范围：node-addon-system-linux-x64 软链真身，删了启动必挂
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHITELIST_FILE="${WHITELIST_FILE:-$SCRIPT_DIR/build-prune-whitelist.json}"

MODE_BEFORE_INSTALL=0
if [[ "${1:-}" == "--before-install" ]]; then
  MODE_BEFORE_INSTALL=1
  BUILD_SRC="${2:?用法: $0 --before-install <BUILD_SRC>}"
  [ -d "$BUILD_SRC" ] || { echo "✗ BUILD_SRC 不存在: $BUILD_SRC" >&2; exit 1; }
else
  TARGET="${1:?用法: $0 <TARGET> [WHITELIST] 或 $0 --before-install <BUILD_SRC>}"
  WHITELIST_FILE="${2:-$WHITELIST_FILE}"
  [ -d "$TARGET" ] || { echo "✗ target 不存在: $TARGET" >&2; exit 1; }
fi

# ==============================================================================
# 模式 A：install 前裁剪 devDependencies（纯白名单）
# ==============================================================================
if [ "$MODE_BEFORE_INSTALL" = "1" ]; then
  echo "▶ install 前裁剪 devDeps（纯白名单）: $BUILD_SRC"
  python3 - "$BUILD_SRC" "$WHITELIST_FILE" <<'PYEOF' 2>/dev/null || true
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
# 模式 B：target 后裁剪（纯白名单）
# ==============================================================================
echo "▶ 裁剪 target: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"

python3 - "$TARGET" "$WHITELIST_FILE" <<'PYEOF' 2>/dev/null || true
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

# 强制排除（即使在白名单里也不保留：体积大 / disabled preset / 非目标平台）
force_exclude = {'@openai/codex', 'claude-agent-sdk', '@anthropic-ai/claude',
                 '@img/sharp-libvips-linuxmusl-x64'}

def pkg_name(pnpm_dir):
    """.pnpm 目录名 → 包名（js-yaml@4.2.0 → js-yaml；@types+js-yaml@4.0.9 → @types/js-yaml）"""
    base = os.path.basename(pnpm_dir)
    m = re.match(r'(@[^@]+|[^@]+)@', base)
    return m.group(1).replace('+', '/') if m else base

# ── 纯白名单裁剪：.pnpm 里不在白名单的一律删 ──
deleted = 0
kept = 0
if os.path.isdir(pnpm):
    for d in sorted(os.listdir(pnpm)):
        full = os.path.join(pnpm, d)
        if not os.path.isdir(full):
            continue
        name = pkg_name(full)
        if name in whitelist and name not in force_exclude:
            kept += 1
        else:
            shutil.rmtree(full, ignore_errors=True)
            deleted += 1

print('  ✓ 纯白名单裁剪: 保留 %d 个, 删除 %d 个 .pnpm 目录（白名单共 %d 项）' % (kept, deleted, len(whitelist)))

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
