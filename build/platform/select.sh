#!/bin/bash
# 平台适配器加载器 —— build-common.sh 只调本文件提供的统一接口，
# 自身不再出现任何平台专有名字（打包脚本路径、版本号字段、平台专属约束）。
#
# 契约（每个适配器必须实现三个钩子，并以 PLATFORM_ADAPTERS+=(<名字>) 注册）：
#   platform_<名字>_derive   <官方完整版本>  → 设置 PLATFORM_VERSION / PLATFORM_BETA；失败返回非 0
#   platform_<名字>_meta                     → 输出要写进 build-meta.env 的若干行
#   platform_<名字>_describe                 → 一行人类可读描述（日志用）
#
# 选择：PLATFORMS 环境变量（空格分隔，缺省同时出两个平台的版本号与 meta 字段，
#       与既有行为一致 —— 打包脚本各自取自己那一段）。

: "${PLATFORMS:=synology fnos}"
PLATFORM_DIR="${PLATFORM_DIR:-$BUILD_ROOT/platform}"
PLATFORM_ADAPTERS=()

for _platform_name in $PLATFORMS; do
  _platform_file="$PLATFORM_DIR/$_platform_name.sh"
  if [ ! -f "$_platform_file" ]; then
    echo "✗ 未知平台适配器：$_platform_name（缺 $_platform_file）" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$_platform_file"
done
unset _platform_name _platform_file

# 逐平台推导版本号，并把各自的 meta 行拼成一段文本
platform_derive_all() {
  local official_version="$1"
  PLATFORM_META_BLOCK=""
  PLATFORMS_DESCRIBE=""
  local adapter
  for adapter in "${PLATFORM_ADAPTERS[@]}"; do
    if ! "platform_${adapter}_derive" "$official_version"; then
      echo "✗ 平台 $adapter 无法把官方版本 $official_version 映射成自己的版本号" >&2
      return 1
    fi
    PLATFORM_META_BLOCK+="$("platform_${adapter}_meta")"$'\n'
    PLATFORMS_DESCRIBE+=" | $("platform_${adapter}_describe")"
  done
  return 0
}
