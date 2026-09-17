#!/usr/bin/env bash
# dsh-skip-quality 本脚本内 `$(fsize` 的三处调用为独立语义（跳过判断/重试判断/结果校验），系辅助函数的正常复用，非重复代码
#
# fetch-release-mt.sh —— 多线程下载本仓库 GitHub Release 资产（SPK/FPK 安装包）
#
# 用法:
#   ./fetch-release-mt.sh                      # 下载最新 release 的全部资产
#   ./fetch-release-mt.sh --tag dsh-v0.1.6-alpha.1   # 指定 tag
#   ./fetch-release-mt.sh --only spk           # 只下 .spk（群晖）
#   ./fetch-release-mt.sh --only fpk           # 只下 .fpk（飞牛）
#   ./fetch-release-mt.sh --threads 16         # 并发连接数（默认 16）
#
# 通道:
#   一律走 api.github.com Git Data API（不直连 github.com/releases/download 的 302，
#   该域名在部分网络下不可达）；token 从 .dsh-home/.dsh/git-push/config.json 的
#   githubToken 读取（插件托管，不落命令行、不打印）。
#   下载器用 aria2c 多连接分段（Range 并发），失败回退 curl 单流。
#
# 产物:
#   release/<tag>/<资产文件名>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="${RELEASE_REPO:-EIGHTfs/DeepSeekHarness-NAS}"
# token 配置文件候选（插件托管；按存在性取第一个，不打印内容）
TOKEN_FILES=(
  "${DSH_TOKEN_FILE:-}"
  "$WS/../../.dsh/git-push/config.json"
  "$WS/../.dsh/git-push/config.json"
  "$HOME/.dsh/git-push/config.json"
)
TAG=""
ONLY=""
THREADS=16
JOBS_PER_FILE=2

usage() { sed -n '3,20p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --only)     ONLY="${2:?--only 需要一个值}"; shift 2 ;;
    --threads)  THREADS="${2:?--threads 需要一个值}"; shift 2 ;;
    --repo)     REPO="${2:?--repo 需要一个值}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------- token 解析（插件托管配置；不打印内容） ----------
read_token() {
  python3 - "${TOKEN_FILES[@]}" <<'PYEOF'
import json, os, sys
for path in sys.argv[1:]:
    if path and os.path.isfile(path):
        try:
            tok = json.load(open(path)).get('githubToken', '').strip()
        except Exception:
            tok = ''
        if tok:
            print(tok)
            break
PYEOF
}
TOKEN="$(read_token)"  # dsh-skip-sensitive dsh-skip-residue 运行时读取，非硬编码凭据
if [[ -z "$TOKEN" ]]; then
  echo "[!] 未取到 GitHub token（查 ${TOKEN_FILES[*]} 的 githubToken）" >&2
  exit 1
fi

api() { curl -s -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }  # dsh-skip-residue 值取自 read_token()，非硬编码

# 认证头（aria2c/curl 共用；避免同一字面量散落多处）
AUTH_HEADER="Authorization: token $TOKEN"

# 文件字节数（不存在输出 0；集中 `stat -c%s` 调用，避免散落重复）
fsize() { stat -c%s "$1" 2>/dev/null || echo 0; }

# ---------- 解析 tag ----------
if [[ -z "$TAG" ]]; then
  TAG="$(api "https://api.github.com/repos/$REPO/releases" \
    | python3 -c "
import json,sys
rs=json.load(sys.stdin)
if not isinstance(rs,list) or not rs: sys.exit('无法获取 release 列表')
print(rs[0]['tag_name'])
")"
  echo "▶ 最新 release: $TAG"
fi

# ---------- 列出资产（name/id/size） ----------
list_assets() {
  api "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | python3 -c "
import json,sys
r=json.load(sys.stdin)
if 'assets' not in r: sys.exit('tag %s 不存在或无权访问: %s' % (r.get('tag_name',''), r.get('message','')))
for a in r['assets']:
    print('%s\t%s\t%s' % (a['name'], a['id'], a['size']))
"
}

OUT_DIR="$WS/release/$TAG"
mkdir -p "$OUT_DIR"

echo "▶ 目标目录: $OUT_DIR"
echo "▶ 下载器: aria2c（-x $THREADS -s $THREADS 分段并发）"

fail=0
while IFS=$'\t' read -r name id size; do
  [[ -z "$name" ]] && continue
  case "$ONLY" in
    spk) [[ "$name" == *.spk ]] || continue ;;
    fpk) [[ "$name" == *.fpk ]] || continue ;;
  esac
  dest="$OUT_DIR/$name"
  want_mb=$(( size / 1024 / 1024 ))

  if [[ -f "$dest" ]] && [[ "$(fsize "$dest")" == "$size" ]]; then
    echo "  ✓ 已存在且大小一致，跳过: $name（${want_mb} MB）"
    continue
  fi

  echo "  ↓ $name（${want_mb} MB）"
  url="https://api.github.com/repos/$REPO/releases/assets/$id"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c --quiet=true --show-console-readout=false \
      --max-connection-per-server="$THREADS" --split="$THREADS" --min-split-size=1M \
      --max-concurrent-downloads="$JOBS_PER_FILE" --continue=true \
      --header="$AUTH_HEADER" \
      --header="Accept: application/octet-stream" \
      --out="$name" --dir="$OUT_DIR" "$url" \
      || { echo "    aria2c 失败，回退 curl"; fail=1; }
  fi
  if [[ ! -f "$dest" ]] || [[ "$(fsize "$dest")" != "$size" ]]; then
    curl -L --fail --progress-bar -H "$AUTH_HEADER" \
      -H "Accept: application/octet-stream" -o "$dest" "$url" || fail=1
  fi

  got="$(fsize "$dest")"
  if [[ "$got" == "$size" ]]; then
    echo "    ✓ 完成 $name（$(du -h "$dest" | cut -f1)）"
  else
    echo "    ✗ 大小不符: 期望 $size 实得 $got" >&2
    fail=1
  fi
done < <(list_assets)

echo ""
echo "▶ 目录内容:"
ls -lh "$OUT_DIR" 2>/dev/null | tail -n +2
exit "$fail"
