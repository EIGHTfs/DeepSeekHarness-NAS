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

# ── 公共函数库（safe_rm_rf：强制 --one-file-system + 挂载点检测）──
_DSH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/common.sh"
[ -f "$_DSH_LIB" ] && . "$_DSH_LIB"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="${RELEASE_REPO:-EIGHTfs/DeepSeekHarness-NAS}"
# token 配置文件候选（兜底路径；按存在性取第一个，不打印内容）。取值优先级见下方 TOKEN= 那行
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
TOKEN_ARG=""          # --token 显式传入（优先于环境变量与配置文件，2026-10-09 用户要求）

usage() { sed -n '3,20p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --only)     ONLY="${2:?--only 需要一个值}"; shift 2 ;;
    --threads)  THREADS="${2:?--threads 需要一个值}"; shift 2 ;;
    --repo)     REPO="${2:?--repo 需要一个值}"; shift 2 ;;
    --token)    TOKEN_ARG="${2:?--token 需要一个值}"; shift 2 ;;
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
# 取值优先级（2026-10-09 用户要求"改成传参传 token"）：
#   ① --token <ghp_...>            显式传参（最高优先）
#   ② DS_FETCH_TOKEN / GH_TOKEN / GITHUB_TOKEN  环境变量（DS_FETCH_TOKEN 与 fetch-dsh-latest.sh 同名同序）
#   ③ 配置文件里的 githubToken     兜底（插件托管路径，见 TOKEN_FILES）
#   ⚠ 三种方式都不会打印 token 内容。
TOKEN="${TOKEN_ARG:-${DS_FETCH_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-$(read_token)}}}}"  # dsh-skip-sensitive dsh-skip-residue 运行时取值，非硬编码凭据
if [[ -z "$TOKEN" ]]; then
  echo "[!] 未取到 GitHub token。三种给法（任选其一）：" >&2
  echo "      ① --token <ghp_...>" >&2
  echo "      ② DS_FETCH_TOKEN=<ghp_...>（或 GH_TOKEN / GITHUB_TOKEN）" >&2
  echo "      ③ 在以下任一文件写 githubToken: ${TOKEN_FILES[*]}" >&2
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

# ---------- aria2c 自动探测 + 缺失下载（2026-10-02） ----------
# 有则用系统/已有的；没有则下载 P3TERX/Aria2-Pro-Core 静态二进制到本项目
# tools/aria2/（自备工具惯例）并注入 PATH，避免每次回退慢速 curl 单流。
ARIA2C="$(command -v aria2c 2>/dev/null || true)"
ensure_aria2c() {
  if [[ -n "$ARIA2C" ]]; then return 0; fi
  local _cand="$WS/tools/aria2/bin/aria2c"
  if [[ -x "$_cand" ]]; then
    ARIA2C="$_cand"; PATH="$WS/tools/aria2/bin:$PATH"; return 0
  fi
  echo "▶ 未检测到 aria2c，下载 P3TERX 静态构建（4.5MB）到 $WS/tools/aria2/"
  mkdir -p "$WS/tools/aria2" "$WS/tools/.aria2-tmp"
  local _tgz="$WS/tools/.aria2-tmp/aria2-static.tar.gz"
  # 资产 id 固定（P3TERX/Aria2-Pro-Core 1.36.0 amd64）；下载失败则保留 curl 回退
  if curl -L --fail --connect-timeout 10 --max-time 120 -H "$AUTH_HEADER" \
      -H "Accept: application/octet-stream" \
      -o "$_tgz" "https://api.github.com/repos/P3TERX/Aria2-Pro-Core/releases/assets/43018056" \
      && tar -xzf "$_tgz" -C "$WS/tools/aria2" 2>/dev/null; then
    # 静态包内含 bin/aria2c（不同版本路径可能不同，兜底 find）
    if [[ ! -x "$WS/tools/aria2/bin/aria2c" ]]; then
      local _found; _found="$(find "$WS/tools/aria2" -name aria2c -type f 2>/dev/null | head -1)"
      [[ -n "$_found" ]] && mkdir -p "$WS/tools/aria2/bin" && cp "$_found" "$WS/tools/aria2/bin/aria2c"
    fi
    chmod +x "$WS/tools/aria2/bin/aria2c" 2>/dev/null || true
    if [[ -x "$WS/tools/aria2/bin/aria2c" ]]; then
      ARIA2C="$WS/tools/aria2/bin/aria2c"; PATH="$WS/tools/aria2/bin:$PATH"
      echo "✓ aria2c 就绪: $ARIA2C"
    else
      echo "  ⚠ aria2c 下载/解压失败，继续用 curl 单流"
    fi
  else
    echo "  ⚠ aria2c 下载失败，继续用 curl 单流"
  fi
  safe_rm_rf "$WS/tools/.aria2-tmp"
}

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
echo "▶ 下载器: $([ -n "$ARIA2C" ] && echo "aria2c（-x $THREADS -s $THREADS 分段并发）" || echo "curl 单流（aria2c 不可用）")"
ensure_aria2c

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
  if [[ -n "$ARIA2C" ]]; then
    "$ARIA2C" --quiet=true --show-console-readout=false \
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
