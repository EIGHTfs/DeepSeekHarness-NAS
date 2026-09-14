#!/usr/bin/env bash
#
# clean-build-artifacts.sh —— 自动清理失败/中间构建产物，回收磁盘
#
# 一键清空 build/ 目录下已移入回收站的失败/中间构建（.trash、.trash-modtest），
# 并可选清理累计的依赖缓存（pnpm-store）。可配置「存活天数」：超过该存活时长的
# 回收站条目才被清理（幂等、可重复运行，不会误删刚移入还在确认期的对象）。
#
# 用法:
#   ./scripts/clean-build-artifacts.sh                   # 清理过期回收站（默认存活 7 天）
#   ./scripts/clean-build-artifacts.sh --age 3           # 存活 3 天以上才清
#   ./scripts/clean-build-artifacts.sh --all             # 清空全部回收站（忽略存活天数）
#   ./scripts/clean-build-artifacts.sh --caches          # 连带清理 pnpm-store / tmp-home 缓存
#   ./scripts/clean-build-artifacts.sh --force           # 首次清空用 rm -rf（磁盘告急；用户确认过）
#   ./scripts/clean-build-artifacts.sh --dry-run         # 只打印将删清单，不动文件（推荐先跑这个）
#
# 安全说明:
#   - 默认只对「回收站」内条目（build/.trash、build/.trash-modtest）做清理，
#     绝不触碰 build/staging（交付物）与 build/spk-build 下的成品/有效构建。
#   - 未加 --force 时用「安全删除即移入项目级 .trash」语义；磁盘告急且对象已在
#     回收站时可用 --force 直接 rm -rf（用户已确认）。
#   - 一律先 --dry-run 预览，确认无误再真删。
#
set -euo pipefail
# shellcheck disable=SC2155
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "$SCRIPT_DIR/../build" && pwd)"

AGE_DAYS=7                 # 存活天数：超过才清
DO_TRASH=1                 # 清理回收站目录
DO_CACHES=0                # 是否连带清理缓存（--caches）
FORCE=0                    # 首次清空直删（rm -rf）
DRY_RUN=0                  # 只预览

usage() { sed -n '2,16p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --age)  AGE_DAYS="${2:?--age 需要一个天数}"; shift 2 ;;
    --all)  AGE_DAYS=0; shift ;;
    --caches) DO_CACHES=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

[ "$DRY_RUN" = "1" ] && PRE="[dry-run] " || PRE=""
_RM() {
  # 安全删除：移入同级 .trash（可恢复）；--force 时直接 rm -rf（已在回收站的垃圾/磁盘告急）
  if [ "$FORCE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then echo "${PRE}rm -rf $1"; else rm -rf "$1"; echo "已 rm -rf: $1"; fi
  else
    local trash stamp t
    trash="$(dirname "$1")/.trash"
    stamp="$(date +%s)"
    t="$trash/$stamp-$(basename "$1")"
    if [ "$DRY_RUN" = "1" ]; then echo "${PRE}mv $1 → $t"; else
      mkdir -p "$trash"
      mv "$1" "$t"; echo "已移入回收站: $1 → $t (超 ${AGE_DAYS} 天会被自动清)"
    fi
  fi
}

echo "═══════════════════════════════════════"
echo "清理失败/中间构建产物  build/（存活窗口 ${AGE_DAYS} 天）"
echo "回收站目录: build/.trash + build/.trash-modtest"
echo "═══════════════════════════════════════"

# ── ① 清理回收站内过期条目 ──
if [ "$DO_TRASH" = "1" ]; then
  for TC in "$BUILD_DIR"/.trash*; do
    [ -d "$TC" ] || continue
    echo "◆ 处理回收站: $TC"
    find "$TC" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r entry; do
      [ -e "$entry" ] || continue
      # 存活时长（天）：比当前时间早 就删。--age 0 即全部。
      if [ "$AGE_DAYS" = "0" ]; then
        _RM "$entry"; continue
      fi
      # 用文件时间戳/MTime 判定存活：超存活天数才清
      if find "$entry" -mtime +"$AGE_DAYS" | grep -q "$entry"; then
        _RM "$entry"
      fi
    done
  done
fi

# ── ② 可选清理依赖缓存 ──
if [ "$DO_CACHES" = "1" ]; then
  echo "◆ 清理缓存:"
  for c in "$BUILD_DIR/../assets/pnpm-store" "$BUILD_DIR/../assets/tmp-home"; do
    if [ -e "$c" ]; then
      [ "$DRY_RUN" = "1" ] && echo "${PRE}rm -rf $c" || { rm -rf "$c"; echo "已清理缓存: $c"; }
    fi
  done
fi

echo "════ 完成 ════"
echo "执行前请确认：df -h 已回落；如需更细粒度请用 --age N 或 --caches 再跑。"