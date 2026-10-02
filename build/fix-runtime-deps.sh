#!/bin/bash
#===============================================================================
# fix-runtime-deps.sh — 运行时精准补包（2026-10-02，探测驱动，不搞全量闭包）
#===============================================================================
# 【背景】裁剪白名单（lockfileDeps，来自 npm 链路 lock）与源码构建的 .pnpm
#   （pnpm 链路）有差异：npm 白名单会把 pnpm 装的运行时传递依赖漏掉
#   （实测 execa 的 is-plain-obj/get-stream/… 被裁）→ 装完 DSH 启动时报
#   "Cannot find package 'x'"（plugin-manager 等内置插件 failed to import）。
#   全量闭包解法（从整个白名单 BFS）会保留几百个开发/测试/构建工具 → 体积膨胀
#   （136MB → 362MB），不值得。
#
# 【本方案】**探测驱动精准补包**：裁剪后逐一 import 运行时核心入口
#   （packages/boot/*/lib/index.js + apps/cli/lib/bin.js）→ 报缺的包
#   从构建副本 BUILD_SRC 的 .pnpm 恢复（pnpm 依赖软链是相对路径，恢复 .pnpm
#   目录即自动生效）→ 迭代到所有入口 import 干净。只补真缺的（实测 execa 依赖
#   链 ~14 个小包），体积保持精准裁剪级（714M → SPK ~137MB）。
#
# 【用法】./build/fix-runtime-deps.sh <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]
#   TARGET      已裁剪的 target（缺包被删）
#   BUILD_SRC   完整构建副本（含全量 node_modules，补包来源）
#   NODE_BIN    node 可执行文件（缺省自探测 tools/node-dist）
#   --max-rounds N  最大迭代轮数（默认 25）
#===============================================================================
set -euo pipefail

TARGET="${1:?用法: $0 <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]}"
BUILD_SRC="${2:?用法: $0 <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]}"
MAX_ROUNDS=25
NODE_BIN=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --max-rounds) MAX_ROUNDS="${2:?}"; shift 2 ;;
    *) NODE_BIN="$1"; shift ;;
  esac
done
[ -n "$NODE_BIN" ] || NODE_BIN="$(ls -d "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1)"
[ -x "$NODE_BIN" ] || { echo "✗ 未找到 node: $NODE_BIN" >&2; exit 1; }
[ -d "$BUILD_SRC/node_modules/.pnpm" ] || { echo "✗ BUILD_SRC 无 node_modules: $BUILD_SRC" >&2; exit 1; }

# 探测：import 运行时核心入口，提取缺失包名（Cannot find package 'x'）
detect() {
  local entry out
  cd "$TARGET" || return
  for entry in packages/boot/*/lib/index.js apps/cli/lib/bin.js; do
    [ -f "$entry" ] || continue
    out=$(timeout 20 "$NODE_BIN" --input-type=module -e "
      try { await import('file://$PWD/$entry'); }
      catch(e) { if (e && e.message) console.log('MISS:' + e.message); }" 2>&1)
    echo "$out" | grep -oE "Cannot find package '[^']+'" | sed "s/Cannot find package '//;s/'//"
  done | sort -u
}

restored=0
for round in $(seq 1 "$MAX_ROUNDS"); do
  missing=$(detect || true)   # detect 内 grep 无匹配时管道非零，set -e 下需 || true
  if [ -z "$missing" ]; then
    echo "✓ 运行时依赖完整（第 $round 轮探测通过）"
    break
  fi
  echo "▶ 第 $round 轮缺包: $(echo "$missing" | tr '\n' ' ')"
  for pkg in $missing; do
    pdir="${pkg//\//+}"   # scoped 包：/ → +（pnpm 目录命名）
    for d in "$BUILD_SRC"/node_modules/.pnpm/"${pdir}"@*; do
      if [ -d "$d" ]; then
        cp -a "$d" "$TARGET/node_modules/.pnpm/" 2>/dev/null || true
        echo "  ✓ 恢复: $(basename "$d")"
        restored=$((restored + 1))
      fi
    done
  done
done

echo "✓ 精准补包完成：恢复 $restored 个缺失包（target=$(du -sh "$TARGET" 2>/dev/null | cut -f1)）"
[ "$restored" -gt 0 ] && exit 0 || true
