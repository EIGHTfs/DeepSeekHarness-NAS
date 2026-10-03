#!/bin/bash
#===============================================================================
# release-note.sh — 统一生成 Release 文案（正文 + 标题）
#   （2026-10-03 建；2026-10-03 扩展：更新日志抓取 + 标题也由此渲染）
#===============================================================================
# 【背景】release body 之前硬编码在 build.yml 的各个 if 分支（SPK/FPK 状态各写各的，
#   文案不统一、难维护）。本脚本用统一函数渲染，workflow 只负责传状态与取值。
#
# 【职责边界（文案的唯一出处）】
#   本脚本负责**所有用户可见文案**：
#     · 正文 render()  —— 状态徽标、官方版本、构建时间、SHA256
#     · 标题 title()   —— Release 名称（workflow 不再写 "$TAG 自动构建" 之类字面文案）
#     · 更新日志 changelog() —— 抓官方**同 tag** Release 正文追加到正文末尾
#   workflow 只传环境变量，不写任何中文文案。
#
# 【更新日志来源与降级】
#   来源：api.github.com `/repos/{官方repo}/releases/tags/{官方tag}` 的 `body`
#         （官方 Releases 正文即更新日志，实测 dsh-v0.2.0-rc.2 正文 3831 字，中英双段）。
#   降级：抓不到/为空 → 只输出一行"可前往官方 Release 查看"的提示。
#         **外部网络失败绝不能让构建变红**，故取日志失败一律 return 0。
#   token：GH_TOKEN 可选（有则带 Authorization，避免 60 次/小时 的匿名限流）。
#
# 【状态徽标】统一函数 badge：success→✅有，skipped→⏭️跳过，其他→❌缺失
#
# 【用法】（环境变量传入，脚本只读不写 workflow）
#   MODE=main|npm    main=源码链路 Release（SPK + FPK 源码版）；npm=独立 npm 链路 Release
#   TRIGGER=<触发方式> RELEASE_TAG=<官方tag> \
#   SPK_STATUS=<success|skipped|fail> SPK_DESC=<源码链路> \
#   FPK_SOURCE_STATUS=<...> FPK_SOURCE_DESC=<源码构建,x86> \
#   FPK_NPM_STATUS=<...> FPK_NPM_DESC=<npm链路,x86> \
#   BUILD_TIME=<ISO时间> SHA256=<多行sha256> GH_TOKEN=<可选> \
#   ./build/release-note.sh          # 正文（默认）→ workflow 重定向到 body_path
#   ./build/release-note.sh title    # Release 标题
#   ./build/release-note.sh changelog# 只输出更新日志段（便于单测/复用）
#===============================================================================
set -euo pipefail

OFFICIAL_REPO="${OFFICIAL_REPO:-deepseek-ai/deepseek-harness}"

# ── 统一状态徽标（文案的唯一出处）─────────────────────────────────────────────
badge() {  # $1=status(success|skipped|fail)  $2=描述
  case "${1:-fail}" in
    success) echo "✅ 有（${2:-}）" ;;
    skipped) echo "⏭️ 跳过" ;;
    *)       echo "❌ 缺失（${2:-}CI 失败）" ;;
  esac
}

# ── 官方 tag 归一：npm 链路的 tag 带 -npm 后缀，官方 Release 不带 ──────────────
official_tag() { echo "${1:-}" | sed 's/-npm$//'; }

# ── 抓官方 Release 正文（更新日志原文）───────────────────────────────────────
# 成功输出正文；任何失败 return 1（由调用方降级），不打印错误、不中断脚本
fetch_release_body() {
  local tag="$1" json="" url auth_hdr=""
  [ -n "$tag" ] || return 1
  url="https://api.github.com/repos/${OFFICIAL_REPO}/releases/tags/${tag}"
  [ -n "${GH_TOKEN:-}" ] && auth_hdr="Authorization: Bearer ${GH_TOKEN}"
  # 显式分支而不是数组展开：兼容 set -u 与旧 bash（空数组展开在 4.4 前会报未绑定）
  if [ -n "$auth_hdr" ]; then
    json=$(curl -fsSL -m 30 -H "$auth_hdr" -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || return 1
  else
    json=$(curl -fsSL -m 30 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || return 1
  fi
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("body") or "", end="")
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# ── 更新日志段：官方同版本日志原文，折叠展示 ────────────────────────────────
changelog() {
  local tag body
  tag="$(official_tag "${1:-${RELEASE_TAG:-}}")"
  if [ -z "$tag" ]; then
    echo "> 未提供官方 tag，跳过更新日志。"
    return 0
  fi
  body="$(fetch_release_body "$tag")" || body=""
  if [ -z "${body//[[:space:]]/}" ]; then
    echo "> 未取到官方 \`${tag}\` 的更新日志，可前往 https://github.com/${OFFICIAL_REPO}/releases/tag/${tag} 查看。"
    return 0
  fi
  echo "<details>"
  echo "<summary>官方更新日志（${tag}）</summary>"
  echo
  # 官方正文自带中英锚点导航，原样抄录以便对照
  printf '%s\n' "$body"
  echo
  echo "</details>"
}

# ── Release 标题（workflow 不再写字面文案）────────────────────────────────────
title() {
  local tag="${RELEASE_TAG:-?}"
  case "${MODE:-main}" in
    npm) echo "${tag} 自动构建（npm 链路）" ;;
    *)   echo "${tag} 自动构建" ;;
  esac
}

# ── 渲染完整正文（MODE=main 源码链 / npm 独立链，两链路不挤同一个 release）──
render() {
  echo "自动构建产物（触发方式: ${TRIGGER:-?}）"
  echo "- 官方版本: ${RELEASE_TAG:-?}"
  case "${MODE:-main}" in
    npm)
      echo "- **FPK（npm 链路）**: $(badge "${FPK_NPM_STATUS:-fail}" "${FPK_NPM_DESC:-}")"
      ;;
    *)
      echo "- **SPK**: $(badge "${SPK_STATUS:-fail}" "${SPK_DESC:-}")"
      if [ -n "${FPK_SOURCE_STATUS:-}" ]; then
        echo "- **FPK（源码构建）**: $(badge "$FPK_SOURCE_STATUS" "${FPK_SOURCE_DESC:-}")"
      fi
      ;;
  esac
  echo "- 构建时间: ${BUILD_TIME:-?}"
  if [ -n "${SHA256:-}" ]; then
    echo "- SHA256 校验:"
    echo '```'
    echo "$SHA256"
    echo '```'
  fi
  echo
  echo "---"
  echo
  echo "## 官方更新日志"
  echo
  changelog ""
}

case "${1:-body}" in
  body)      render ;;
  title)     title ;;
  changelog) changelog "${2:-}" ;;
  *)         echo "用法: $0 [body|title|changelog [tag]]" >&2; exit 2 ;;
esac
