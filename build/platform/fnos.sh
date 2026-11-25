#!/bin/bash
# 飞牛（FPK）平台适配器 —— 只放「飞牛专有」的东西，平台无关逻辑一律不进本文件。
#
# 飞牛的 manifest 接受带预发布后缀的完整版本串（与群晖相反），
# 所以这里直接用官方完整版本，不做任何映射。

platform_fnos_derive() {
  PLATFORM_VERSION="$1"
  PLATFORM_BETA="no"
  return 0
}

platform_fnos_meta() {
  printf "FPK_VERSION='%s'\n" "$PLATFORM_VERSION"
}

platform_fnos_describe() {
  printf "FPK %s（完整）" "$PLATFORM_VERSION"
}

# 注册到适配器表（加载器按 PLATFORM_ADAPTERS 顺序回调三个钩子）
PLATFORM_ADAPTERS+=("fnos")
