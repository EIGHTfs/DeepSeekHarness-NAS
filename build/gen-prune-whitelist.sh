#!/bin/bash
#===============================================================================
# gen-prune-whitelist.sh — 从 npm 锁文件自动生成源码构建裁剪白名单
#===============================================================================
# 【用途】npm 链路（build-npm-app.sh）的 package-lock.json 是官方依赖的完整
#   事实清单：磁盘实际包 522 个全部落在锁文件 582 条引用内（2026-09-13 实测，
#   0 个磁盘有锁文件无）。因此源码构建（build-common.sh）裁剪时的白名单可直接
#   由锁文件自动生成，取代手工维护 —— 锁文件有的包一律保留，跑不掉的依赖
#   不会因清单遗漏被误删。
#
# 【用法】
#   ./build/gen-prune-whitelist.sh                 # 自动找最新锁文件 → 更新白名单
#   ./build/gen-prune-whitelist.sh <锁文件路径>    # 指定锁文件
#   ./build/gen-prune-whitelist.sh --dry-run       # 只打印将要写入的包名数，不写盘
#
# 【输出】更新 build/build-prune-whitelist.json 的 lockfileDeps 字段（全量包名，
#   与 extra / workspaceRuntimeDeps 并列，白名单三者取并集）。字段缺失时自动补。
#   包名从 packages 键路径解析（node_modules/js-yaml → js-yaml、
#   node_modules/@types/js-yaml → @types/js-yaml），与黑名单 pkg_name() 的
#   .pnpm 目录名解析（+ → /）格式对齐。
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
WHITELIST_FILE="$SCRIPT_DIR/build-prune-whitelist.json"

# ── 锁文件定位（缺省：最新 npm-app 产物） ──
LOCK_FILE="${1:-}"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  LOCK_FILE=""
fi
if [ -z "$LOCK_FILE" ]; then
  LOCK_FILE="$(ls -1t "$WS"/build/spk-build/npm-app-*/node-v*/dsh-web/package-lock.json 2>/dev/null | head -1 || true)"
fi
if [ -z "$LOCK_FILE" ] || [ ! -f "$LOCK_FILE" ]; then
  echo "✗ 未找到 package-lock.json（先运行 ./build/build-npm-app.sh 或指定路径）" >&2
  exit 1
fi

# ── 解析锁文件 → 包名全集（写入 stdout: 每行一个包名） ──
# 排除平台变体：锁文件含全部平台的可选依赖（sharp-darwin/win32-process 等），
# 若进白名单会保护黑名单该删的平台变体（白大于黑 → 不删 → 体积膨胀）。
# 排除关键词复用 build-prune-blacklist.json 的 pnpmPlatform + pnpmMusl + pnpmApps。
TMP_LIST="$(mktemp)"
python3 - "$LOCK_FILE" "$SCRIPT_DIR/build-prune-blacklist.json" <<'PYEOF' > "$TMP_LIST"
import json, sys
lock_path, black_path = sys.argv[1], sys.argv[2]
black = json.load(open(black_path, encoding='utf-8'))
skip_keys = set(black.get('pnpmPlatform', [])) | set(black.get('pnpmMusl', [])) | set(black.get('pnpmApps', []))
d = json.load(open(lock_path, encoding='utf-8'))
pkgs = d.get('packages', {})
names = set()
for k in pkgs:
    if not k.startswith('node_modules/'):
        continue
    rest = k[len('node_modules/'):]
    last = rest.split('/node_modules/')[-1]   # 含嵌套取最后一段
    if not last:
        continue
    if any(sk in last for sk in skip_keys):
        continue                      # 平台变体 / claude / codex，不保护
    names.add(last)
for n in sorted(names):
    print(n)
PYEOF

COUNT="$(wc -l < "$TMP_LIST" | tr -d ' ')"
echo "锁文件 : $LOCK_FILE"
echo "包名全量: $COUNT 个（写入白名单 lockfileDeps 字段）"

if [ "$DRY_RUN" = "1" ]; then
  echo "（--dry-run 未写盘；前 10 个: ）"
  head -10 "$TMP_LIST" | sed 's/^/    /'
  rm -f "$TMP_LIST"
  exit 0
fi

# ── 更新 build-prune-whitelist.json（保留原结构，lockfileDeps 追加/覆盖） ──
python3 - "$WHITELIST_FILE" "$TMP_LIST" "$COUNT" <<'PYEOF'
import json, sys
white_file, list_file, count = sys.argv[1], sys.argv[2], sys.argv[3]
with open(white_file, encoding='utf-8') as f:
    cfg = json.load(f)
import os
with open(list_file, encoding='utf-8') as f:
    names = [l.strip() for l in f if l.strip()]
cfg['lockfileDeps'] = names
cfg['_lockNote'] = (f"自动生成 {count} 个（{os.path.basename(list_file)} 来源的 npm 锁文件 packages 键），"
                    f"2026-09-13 gen-prune-whitelist.sh 写入；与 extra/workspaceRuntimeDeps 取并集")
with open(white_file, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f"✓ 已更新 {os.path.basename(white_file)}（lockfileDeps={count}）")
PYEOF

rm -f "$TMP_LIST"