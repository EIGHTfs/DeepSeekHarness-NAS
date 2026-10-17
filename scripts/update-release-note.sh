#!/bin/bash
#===============================================================================
# update-release-note.sh — 独立更新某个 Release 的正文（不需要重新构建 ✓）
#
# 为什么需要（用户 2026-10-15 定）：文案（触发方式/官方版本/构建时间 + 官方更新日志）
#   原来只在【构建时】由 build/release-note.sh 生成 ✗ —— 改个措辞就要跑一次完整构建 ✗
#   （十几分钟到一小时 ✗ 还会重发一遍产物 ✗）。本脚本让文案可以【单独刷新】✓。
#
# 单一真相：正文一律由 build/release-note.sh 渲染 ✓（本脚本不复制模板 ✗），
#   因此构建时与单独更新时生成的文案【逐字一致】✓。
#
# 用法:
#   GH_TOKEN=… ./scripts/update-release-note.sh --tag dsh-v0.2.1-alpha.3
#   GH_TOKEN=… ./scripts/update-release-note.sh --tag <tag> --trigger push --dry-run
#   省略 --tag → 用最新 Release；--dry-run → 只打印将写入的正文，不改远端 ✓
#
# 退出码：0 成功（含 dry-run）/ 1 参数·网络·接口错误
#===============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TAG=""; TRIGGER="workflow_dispatch"; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --trigger) TRIGGER="${2:?--trigger 需要一个值}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "✗ 未知参数: $1" >&2; exit 1 ;;
  esac
done

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "✗ 缺少 GH_TOKEN / GITHUB_TOKEN" >&2; exit 1; }
REPO="${GITHUB_REPOSITORY:-EIGHTfs/DeepSeekHarness-NAS}"
API="https://api.github.com/repos/$REPO"

if [ -z "$TAG" ]; then
  TAG="$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" "$API/releases/latest" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))')"
  [ -n "$TAG" ] || { echo "✗ 取不到最新 Release tag" >&2; exit 1; }
  echo "▶ 未指定 --tag，使用最新 Release: $TAG"
fi

RID="$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" "$API/releases/tags/$TAG" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"
[ -n "$RID" ] || { echo "✗ 找不到 Release: $TAG" >&2; exit 1; }

# 正文一律由同一个模板渲染（构建时与单独更新时结果一致 ✓）
# 构建时间用北京时间（与 build.yml 一致 ✓）
# ★ 注释绝不能写在 $( … ) 里 ✗ —— 2026-10-18 实测：行内 # 会把后半截（含 release-note.sh 调用）
#   整段注释掉 → BODY 异常 → 推上去的正文三个字段全是 "?" ✗
BUILD_TIME="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S +08:00')"
BODY="$(MODE=main TRIGGER="$TRIGGER" RELEASE_TAG="$TAG" BUILD_TIME="$BUILD_TIME" \
        GH_TOKEN="$TOKEN" ./build/release-note.sh)"
echo "▶ 已按 build/release-note.sh 渲染正文（$(printf '%s' "$BODY" | wc -c) 字符）"
echo "── 正文前 6 行 ──"
printf '%s\n' "$BODY" | head -6 | sed 's/^/   /'

if [ "$DRY" = "1" ]; then
  echo "▶ --dry-run：未改动远端 ✓（Release $TAG，id=$RID）"
  exit 0
fi

# ★ 正文必须走【环境变量】而不是 stdin ✗：下面用 heredoc 传脚本，stdin 已被 heredoc 占用 ✗
#   （2026-10-15 实测事故：用 sys.stdin.read() 读到空 → Release 正文被清成 0 字符 ✗）
[ -n "$BODY" ] || { echo "✗ 渲染出的正文为空，拒绝写入（防把 Release 正文清空）" >&2; exit 1; }
BODY="$BODY" python3 - "$TOKEN" "$API" "$RID" <<'PY'
import json, os, sys, urllib.request
tok, api, rid = sys.argv[1], sys.argv[2], sys.argv[3]
body = os.environ.get('BODY', '')
if not body.strip():
    sys.exit('✗ BODY 为空，拒绝写入')
req = urllib.request.Request(api + '/releases/' + rid, method='PATCH',
        data=json.dumps({'body': body}).encode('utf-8'),
        headers={'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json'})
with urllib.request.urlopen(req, timeout=30) as r:
    d = json.load(r)
print('▶ ✓ 已更新 Release %s 的正文（%d 字符）' % (d.get('tag_name'), len(d.get('body') or '')))
PY
