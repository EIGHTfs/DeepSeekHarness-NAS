#!/bin/bash
#===============================================================================
# prune-target.sh — 黑白名单裁剪（install 前 / target 后 双模式，独立可跑）
#===============================================================================
# 【用途】从 build-common.sh 提取的「黑白名单裁剪」逻辑，独立成脚本，两种模式：
#
#  模式 A：install 前（--before-install <BUILD_SRC>）
#    pnpm install **之前** 对源码副本 BUILD_SRC 各 package.json 的 devDependencies
#    应用黑白名单：黑名单 devDeps 候选（根 devDependencies 全集）→ 白名单
#    （extra + lockfileDeps + workspaceRuntimeDeps）保护 → 删除非白名单 devDep。
#    效果：install 阶段不再下载被裁 devDeps（官方 monorepo ~1.78万包，
#    vitest/jsdom/mermaid 等巨大），CI runner 磁盘峰值骤降，不再被
#    "No space left on device" 杀 worker（2026-09-14 annotation 实测根因）。
#    构建必需工具（typescript/tsx/tsdown/lightningcss/execa/smol-toml）已手动追加进
#    白名单 extra，install 时保留，build 不会缺工具。
#
#  模式 B：target 后（默认 <TARGET> [BLACKLIST] [WHITELIST]）
#    对已构建 target 应用黑白名单裁剪（原行为不变）：
#    黑名单收集 .pnpm 候选（平台变体/musl/claude/codex/devDeps）→ 白名单过滤 → rm -rf
#    + sourceDirs 源码/文档裁剪。白名单 lockfileDeps 更新后可单独重裁 target 免重编译。
#
# 【规则】执行顺序：黑名单收集候选 → 白名单过滤（命中 = 保留，白大于黑）→ 删除
#   白名单 = extra + lockfileDeps（gen-prune-whitelist.sh 自动生成，不覆盖手动 extra）
#          + workspaceRuntimeDeps（动态收集 packages/*/package.json dependencies）
#   ⚠ native/ 不在黑名单 sourceDirs：node-addon-system-linux-x64 软链真身，删了启动必挂
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLACKLIST_FILE="${BLACKLIST_FILE:-$SCRIPT_DIR/build-prune-blacklist.json}"
WHITELIST_FILE="${WHITELIST_FILE:-$SCRIPT_DIR/build-prune-whitelist.json}"

MODE_BEFORE_INSTALL=0
if [[ "${1:-}" == "--before-install" ]]; then
  MODE_BEFORE_INSTALL=1
  BUILD_SRC="${2:?用法: $0 --before-install <BUILD_SRC>}"
  [ -d "$BUILD_SRC" ] || { echo "✗ BUILD_SRC 不存在: $BUILD_SRC" >&2; exit 1; }
else
  TARGET="${1:?用法: $0 <TARGET> [BLACKLIST] [WHITELIST] 或 $0 --before-install <BUILD_SRC>}"
  BLACKLIST_FILE="${2:-$BLACKLIST_FILE}"
  WHITELIST_FILE="${3:-$WHITELIST_FILE}"
  [ -d "$TARGET" ] || { echo "✗ target 不存在: $TARGET" >&2; exit 1; }
fi

# ==============================================================================
# 模式 A：install 前裁剪 devDependencies（复用黑白名单）
# ==============================================================================
if [ "$MODE_BEFORE_INSTALL" = "1" ]; then
  echo "▶ install 前裁剪 devDeps（复用黑白名单）: $BUILD_SRC"
  python3 - "$BUILD_SRC" "$BLACKLIST_FILE" "$WHITELIST_FILE" <<'PYEOF' 2>/dev/null || true
import json, os, sys
build_src, black_file, white_file = sys.argv[1], sys.argv[2], sys.argv[3]
black = json.load(open(black_file, encoding='utf-8'))
white = json.load(open(white_file, encoding='utf-8'))

# 白名单集合：extra + lockfileDeps + workspaceRuntimeDeps（动态收集 packages 运行时依赖）
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

# 黑名单 devDeps=true：根 devDependencies 全集为裁剪候选（白名单保护的保留）
candidates = []
if black.get('devDeps'):
    root_pkg = os.path.join(build_src, 'package.json')
    try:
        root_dev = json.load(open(root_pkg, encoding='utf-8')).get('devDependencies') or {}
        candidates = [k for k in root_dev if k not in whitelist]
    except Exception:
        pass

if candidates:
    # 从根 package.json 删除非白名单 devDeps（install 不再下载）
    try:
        data = json.load(open(root_pkg, encoding='utf-8'))
        dev = data.get('devDependencies') or {}
        for k in candidates:
            dev.pop(k, None)
        data['devDependencies'] = dev
        with open(root_pkg, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"  ✓ 剥离 {len(candidates)} 个非白名单 devDeps: {', '.join(candidates[:8])}{'...' if len(candidates)>8 else ''}")
        # 同步清理 pnpm-workspace.yaml 的 patchedDependencies：被剥离 devDeps 的补丁
        # 声明会悬空 → pnpm install 报 ERR_PNPM_UNUSED_PATCH（实测 @yao-pkg/pkg@6.21.0）
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
    except Exception as e:
        print(f"  ⚠ 剥离失败: {e}")
else:
    print("  ✓ 无非白名单 devDeps 需剥离")
PYEOF
  exit 0
fi

# ==============================================================================
# 模式 B：target 后裁剪（原行为）
# ==============================================================================
echo "▶ 裁剪 target: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"

python3 - "$TARGET" "$BLACKLIST_FILE" "$WHITELIST_FILE" <<'PYEOF' 2>/dev/null || true
import json, glob, os, re, shutil, sys
target, black_file, white_file = sys.argv[1], sys.argv[2], sys.argv[3]
black = json.load(open(black_file, encoding='utf-8'))
white = json.load(open(white_file, encoding='utf-8'))
pnpm = os.path.join(target, 'node_modules', '.pnpm')

# ── 白名单集合（纯白名单模式：只保留这些，其余全删） ──
# 模式 B 只用运行时依赖（lockfileDeps + workspaceRuntimeDeps），不用 extra
#（extra 里的类型检查包只在模式 A 保护 tsc，不需要进最终 target）
whitelist = set(white.get('lockfileDeps', []))

# 强制排除（即使在白名单里也不保留：体积大 / disabled preset / 非目标平台）
force_exclude = {'@openai/codex', 'claude-agent-sdk', '@anthropic-ai/claude',
                 '@img/sharp-libvips-linuxmusl-x64'}
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

# 源码/文档裁剪（sourceDirs；native/ 不在列表 → 保留）
for pat in black.get('sourceDirs', []):
    for p in glob.glob(os.path.join(target, pat)):
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p, ignore_errors=True)
for f in ['tsconfig.host.tsbuildinfo', 'tsconfig.client.tsbuildinfo']:
    p = os.path.join(target, f)
    if os.path.isfile(p):
        os.remove(p)
PYEOF
echo "  ✓ 源码/文档裁剪: 按黑名单 sourceDirs 删除（native 保留；lib/dist 产物保留）"

# 修正权限（tar 打包把 0707 带进包 → 安装报错；目录755 文件644 脚本755）
find "$TARGET" -type d -exec chmod 755 {} + 2>/dev/null
find "$TARGET" -type f ! -executable -exec chmod 644 {} + 2>/dev/null
find "$TARGET" -type f -executable -exec chmod 755 {} + 2>/dev/null

echo "✓ 裁剪完成: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"