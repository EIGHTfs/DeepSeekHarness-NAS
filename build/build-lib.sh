#!/usr/bin/env bash
#===============================================================================
# build/build-lib.sh — **薄转发**（唯一公共库是 scripts/lib/common.sh）
#
# 2026-10-04 用户口径：「此次一鼓作气把所有能公共的都公共」。
#   原 build-lib.sh 里的 gen_start_sh() 已迁入 scripts/lib/common.sh，
#   本文件只做转发，保证既有 `source "$BUILD_ROOT/build-lib.sh"` 的脚本零改动。
#
# 【用法】在打包脚本里（BUILD_ROOT 已定义之后）：
#     . "$BUILD_ROOT/build-lib.sh"
#
# 【约定】
#   · 本文件**不再定义任何函数**（否则 scripts/check-common-functions.sh 会失败）。
#   · 新增公共函数一律加到 scripts/lib/common.sh，不要加回这里。
#===============================================================================

_DSH_BUILD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DSH_COMMON_LIB="${_DSH_COMMON_LIB:-$_DSH_BUILD_LIB_DIR/../scripts/lib/common.sh}"

if [ ! -f "$_DSH_COMMON_LIB" ]; then
  echo "✗ 缺少公共函数库: $_DSH_COMMON_LIB" >&2
  echo "  （唯一公共库是 scripts/lib/common.sh；build-lib.sh 只是薄转发）" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
. "$_DSH_COMMON_LIB"
