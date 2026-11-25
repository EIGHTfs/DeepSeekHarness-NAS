#!/bin/bash
# 群晖（SPK）平台适配器 —— 只放「群晖专有」的东西，平台无关逻辑一律不进本文件。
#
# 群晖的硬约束：INFO 的 version 每段只允许数字，预发布信息只能编码进 build 段。
#   映射规则与边界（阶段基数、序号上限、未知阶段报错）在 build/spk-version.py，
#   对应测试 test/spk-version-scheme.test.sh，说明见 docs/打包规范.md「版本号映射」。

platform_synology_derive() {
  local official_version="$1"
  PLATFORM_VERSION="$(python3 "$WS/build/spk-version.py" "$official_version")" || return 1
  PLATFORM_BETA="$(python3 "$WS/build/spk-version.py" "$official_version" --field beta 2>/dev/null || echo no)"
  return 0
}

platform_synology_meta() {
  printf "SPK_VERSION='%s'\n" "$PLATFORM_VERSION"
  printf "SPK_BETA='%s'\n" "$PLATFORM_BETA"
}

platform_synology_describe() {
  printf "SPK %s（beta=%s）" "$PLATFORM_VERSION" "$PLATFORM_BETA"
}

# 注册到适配器表（加载器按 PLATFORM_ADAPTERS 顺序回调三个钩子）
PLATFORM_ADAPTERS+=("synology")
