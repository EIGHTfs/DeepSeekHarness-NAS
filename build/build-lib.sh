#!/usr/bin/env bash
#===============================================================================
# build/build-lib.sh — **薄转发**（唯一公共库是 scripts/lib/common.sh）
#
# 【为什么会有这个文件】
#   用户口径：「此次一鼓作气把所有能公共的都公共」。原先 gen_start_sh() 等函数定义在本文件里，
#   已全部迁入 scripts/lib/common.sh。但历史上多个打包脚本写的是
#       . "$BUILD_ROOT/build-lib.sh"
#   为了**不改动这些调用点**（少一次改动就少一次坏包风险），本文件保留为**转发壳**：
#   它只 source 公共库，自身不再提供任何实现。
#
# 【用法】在打包脚本里（BUILD_ROOT 已定义之后）：
#     . "$BUILD_ROOT/build-lib.sh"
#   等价于直接 source scripts/lib/common.sh，只是路径更短、且兼容旧调用点。
#
# 【约定】
#   · 本文件**不再定义任何函数**。这不是风格问题：scripts/check-common-functions.py（CI 守卫）
#     会从公共库派生函数清单并断言全仓库无第二处定义，此处一旦新增同名函数 CI 立即变红。
#     （注：守卫文件是 .py；早期文档曾误写为 .sh，已修正。）
#   · 新增公共函数一律加到 scripts/lib/common.sh，不要加回这里。
#   · 本文件允许**有副作用**（它被 source 时就会去 source 公共库），但仍保持最小：
#     只做路径解析 + 存在性检查 + source，不 set -e/-u、不 cd、不打印成功信息。
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
