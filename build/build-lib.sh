#!/bin/bash
#===============================================================================
# build-lib.sh — SPK/FPK 打包脚本的公共函数库（2026-10-03）
#===============================================================================
# 【用途】由 build-spk.sh / build-fpk.sh **source**，放两边共用的构建级函数。
#
# 【为什么本库只有这些——完整梳理口径，别再重复排查】
#   2026-10-03 全量梳理两个打包脚本（build-spk.sh 637 行 / build-fpk.sh 739 行），
#   按「函数定义是否落在 heredoc 内」逐一定位：
#
#   ① heredoc **外**的构建级函数：只有 gen_start_sh() —— 两边逐字重复，本库收编。
#
#   ② heredoc **内**的函数（log_msg / load_variables_from_file / _app_dir /
#      _version_from / pkg_version / pkg_version_resolved / running_dsh /
#      start|stop|status / start_process|stop_process|status_process / service_* /
#      install_callback …）：它们是**生成给安装包的独立脚本内容**
#      （群晖 scripts/installer；飞牛 cmd/main、cmd/service-setup、cmd/package），
#      安装/运行期由 DSM 或 fnOS 各自执行，**必须自包含**，无法 source 外部文件共用。
#      所以这些"看着重复"之处不是漏抽公共函数，而是包格式的硬约束；
#      要共用只能改成「本库保存母版片段 + 注入 heredoc」，收益小、改动面大，暂不做。
#
#   ③ 真正跨件重复的是**版本号解析口径**（dsh 包 → npm 编译产物 → 顶层 package.json，
#      顺序取自 build-config.yaml 的 brand_version_order）。它同时出现在：
#        · build/start.sh.example         的 _version_from + resolve_pkg_version
#        · build-spk.sh 生成的 installer  的 pkg_version + pkg_version_resolved
#        · build-fpk.sh 生成的 cmd/main   与 cmd/package 的 _version_from
#      口径一致性靠「改一处同步其余」的约定保证，各点注释均指向同一来源。
#      （若将来要彻底收口，做法是在本库存一份母版文本、由生成器注入各 heredoc。）
#
# 【用法】在打包脚本里（BUILD_ROOT 已定义之后）：
#     . "$BUILD_ROOT/build-lib.sh"
#===============================================================================

# ----------------------------------------------------------------------------
# start.sh 生成：母版占位符 → 配置值（SPK/FPK 共用）
#   母版：$BUILD_ROOT/start.sh.example（所有可变值一律来自 build-config.yaml，
#   禁止在脚本或母版里写死端口/包名/品牌字面量）
#   占位符清单与 build-spk.sh / build-fpk.sh 的生成期校验保持一致。
#
#   $1 输出路径  $2 proxy 端口  $3 dsh 端口  $4 容器端口  $5 portal_desc
#   ⚠ 第 5 参（门户描述）**必传**：SPK 与 FPK 的兜底口径不同（SPK 直接用
#     CFG_DESC_SHORT；FPK 为空时回退 "<display_name> Web UI"），由调用方决定，
#     本函数不做兜底，避免把一方的口径悄悄套到另一方。
# ----------------------------------------------------------------------------
gen_start_sh() {
  local out="$1" proxy="$2" dsh="$3" cont="$4"
  local desc="${5?gen_start_sh: 第 5 参 portal_desc 必传（口径由调用方决定）}"
  sed -e "s|__PROXY_PORT__|${proxy}|g" \
      -e "s|__DSH_PORT__|${dsh}|g" \
      -e "s|__CONTAINER_PORT__|${cont}|g" \
      -e "s|__APP_NAME__|${APP_NAME}|g" \
      -e "s|__APP_ID__|${APP_ID}|g" \
      -e "s|__BRAND_NAME__|${CFG_BRAND_NAME}|g" \
      -e "s|__BRAND_VERSION_ORDER__|${CFG_BRAND_VERSION_ORDER}|g" \
      -e "s|__FPK_VERSION__|${FPK_VERSION}|g" \
      -e "s|__PORTAL_TITLE__|${CFG_TITLE}|g" \
      -e "s|__PORTAL_DESC__|${desc}|g" \
      "$BUILD_ROOT/start.sh.example" > "$out"
  chmod +x "$out"
  if grep -qE "__PROXY_PORT__|__DSH_PORT__|__CONTAINER_PORT__|__APP_NAME__|__APP_ID__|__BRAND_NAME__|__BRAND_VERSION_ORDER__|__FPK_VERSION__|__PORTAL_TITLE__|__PORTAL_DESC__" "$out"; then
    echo "[!] start.sh 占位符未全部替换: $out" >&2; exit 1
  fi
}
