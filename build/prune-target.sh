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

# 白名单集合：workspace 运行时依赖（动态收集）+ lockfileDeps（npm 锁文件自动生成）+ extra
whitelist = set(white.get('extra', []))
whitelist.update(white.get('lockfileDeps', []))
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

# 黑名单收集候选删除（.pnpm 目录）
candidates = set()
if os.path.isdir(pnpm):
    all_dirs = [os.path.join(pnpm, d) for d in os.listdir(pnpm) if os.path.isdir(os.path.join(pnpm, d))]
    # ① 平台变体（排除 linux-x64）
    plat_re = re.compile('|'.join(re.escape(p) for p in black.get('pnpmPlatform', [])), re.I)
    candidates.update(d for d in all_dirs if plat_re.search(os.path.basename(d)) and 'linux-x64' not in os.path.basename(d))
    # ② musl
    musl_re = re.compile('|'.join(re.escape(p) for p in black.get('pnpmMusl', [])), re.I)
    candidates.update(d for d in all_dirs if musl_re.search(os.path.basename(d)))
    # ③ claude/codex
    app_re = re.compile('|'.join(re.escape(p) for p in black.get('pnpmApps', [])), re.I)
    candidates.update(d for d in all_dirs if app_re.search(os.path.basename(d)))
    # ④ devDeps（动态读根 package.json，精确匹配包名 esc@ 前缀）
    if black.get('devDeps'):
        try:
            root_deps = json.load(open(os.path.join(target, 'package.json'), encoding='utf-8')).get('devDependencies') or {}
            for dep in root_deps:
                esc = dep.replace('/', '+')
                candidates.update(d for d in all_dirs if os.path.basename(d).startswith(esc + '@'))
        except Exception:
            pass

# 白名单过滤：候选包名命中白名单 → 保留（白大于黑）
before = len(candidates)
protected = sorted({d for d in candidates if pkg_name(d) in whitelist})
to_delete = sorted(d for d in candidates if pkg_name(d) not in whitelist)

if protected:
    print('  (白名单保护 %d 个: %s)' % (len(protected), ', '.join(pkg_name(d) for d in protected[:8]) + ('...' if len(protected) > 8 else '')))
if to_delete:
    for d in to_delete:
        shutil.rmtree(d, ignore_errors=True)
    print('  ✓ 依赖裁剪: 删除 %d 个 .pnpm 目录（黑名单 %d - 白名单 %d）' % (len(to_delete), before, len(protected)))
else:
    print('  ✓ 依赖裁剪: 黑名单 %d 个候选全被白名单保护，无需删除' % before)

# ⑤ 源码/文档裁剪（sourceDirs；native/ 不在列表 → 保留）
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