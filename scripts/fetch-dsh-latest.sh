#!/usr/bin/env bash
#
# fetch-dsh-latest.sh —— 一键拉取 DSH（DeepSeek Harness）官方最新版源码到 src/deepseek-ai/{tag}
#
# 用法:
#   ./fetch-dsh-latest.sh                        # 拉取官方最新 tag
#   ./fetch-dsh-latest.sh --tag dsh-v0.1.5-rc.2  # 指定某 tag（不自动判定最新）
#   ./fetch-dsh-latest.sh --repo owner/name      # 指定官方仓库（默认 deepseek-ai/deepseek-harness）
#   ./fetch-dsh-latest.sh --src-dir DIR          # 指定存放目录（默认 <脚本目录>/src/deepseek-ai）
#   ./fetch-dsh-latest.sh --token '<ghp>'       # 显式传入 GitHub token（脚本不自找凭据文件）
#                                               #   ⚠ 建议配合环境变量 DS_FETCH_TOKEN（避免进 history）
#
# 策略:
#   版本: 从 GitHub 拉取全部 tags，用严格 semantic version(含 pre-release)比较，自动选最高 tag。
#   通道: 版本信息一律走 api.github.com；下载**优先本地 git 缓存增量拉取**（复用旧快照/
#         镜像，只下增量，`git archive` 出快照），再退化到 git clone，最后回退 api/zipball。
#   去重: 目标 src/deepseek-ai/{tag} 目录已存在且非空 → 跳过不覆盖，重复运行不重复下载。
#
set -euo pipefail

# ---------- 定位脚本目录与仓库根（src 在仓库根，本脚本在 scripts/ 下） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- 默认与可配置项（可用命令行参数覆盖，不硬编码场景外路径） ----------
DEFAULT_REPO="deepseek-ai/deepseek-harness"
DEFAULT_SRC="$WS/src/deepseek-ai"
TMP_PREFIX=".dsh-fetch-$$"
TARGET_TAG=""          # 空 = 自动判定最新
PRINT_TAG=0            # --print-tag: 只打印 tag 不下载（CI 发布用）
FETCH_TOKEN=""         # GitHub token：只接受显式传入（--token 或环境变量 DS_FETCH_TOKEN），不自找凭据文件

usage() {
  sed -n '2,14p' "$0"
}

# ---------- 解析参数 ----------
REPO="$DEFAULT_REPO"
SRC_DIR="$DEFAULT_SRC"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      TARGET_TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --print-tag) PRINT_TAG=1; shift ;;   # 只解析并打印官方 tag（不下载；CI 发布用）
    --repo)     REPO="${2:?--repo 需要一个值}"; shift 2 ;;
    --src-dir)  SRC_DIR="${2:?--src-dir 需要一个值}"; shift 2 ;;
    --token)    FETCH_TOKEN="${2:?--token 需要一个值}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

# token 显式传入优先：--token > 环境变量 DS_FETCH_TOKEN；两者都没有则匿名（限流更低）
if [[ -z "$FETCH_TOKEN" && -n "${DS_FETCH_TOKEN:-}" ]]; then
  FETCH_TOKEN="$DS_FETCH_TOKEN"
fi

# ---------- 确定存放目录 ----------
[[ "$SRC_DIR" == "$DEFAULT_SRC" ]] && SRC_DIR="$WS/src/deepseek-ai"
mkdir -p "$SRC_DIR"

# ---------- 解析 git 可执行文件（不假设 PATH 里有 git） ----------
# 实测（193，2026-10-03）：群晖上 git 在 /var/packages/git/target/bin，PATH 里没有 →
#   原脚本 `git clone` 直接 "git: command not found" 静默失败、每次都退化成全量 zipball。
#   这里显式解析，并把「没有 git」明确告知（而不是让人以为只是网络问题）。
GIT_BIN="$(command -v git 2>/dev/null || true)"
if [[ -z "$GIT_BIN" ]]; then
  for _c in /var/packages/git/target/bin/git /usr/local/bin/git /usr/bin/git /bin/git; do
    [[ -x "$_c" ]] && { GIT_BIN="$_c"; break; }
  done
fi
[[ -n "$GIT_BIN" ]] || echo "… 本机未找到 git，跳过增量通道（可装 git 或设 DSH_GIT_BIN）…" >&2

# ---------- 利用 python3 做严格 semver 比较并选出最高 tag（含 pre-release） ----------
pick_latest_tag() {
  # tags 判定：token 只来自显式传参（--token 或环境变量 DS_FETCH_TOKEN，见参数解析），
  # 脚本不自找凭据文件（用户要求 2026-10-02）。无 token 则匿名（限流 60 次/h）。
  local _hdr=()
  [[ -n "$FETCH_TOKEN" ]] && _hdr=(-H "Authorization: token $FETCH_TOKEN")
  TAGS_JSON="$(curl -s --connect-timeout 8 --max-time 20 --retry 5 --retry-delay 3 "${_hdr[@]}" \
    "https://api.github.com/repos/$REPO/tags?per_page=300" || true)"
  if [[ -z "$TAGS_JSON" || -z "$(echo "$TAGS_JSON" | grep -o '\"name\"')" ]]; then
    echo "✗ 无法从 api.github.com 获取 $REPO 的 tags（网络或限速）。" >&2
    return 1
  fi
  echo "$TAGS_JSON" | python3 -c '
import sys, json, re
tags = [t["name"] for t in json.load(sys.stdin)]
def parse(v):
    v = re.sub(r"\A[^0-9]*", "", v)   # 去掉 dsh-v 等非数字前缀
    pre = ""
    if "-" in v:
        v, pre = v.split("-", 1)
    core = [int(x) for x in v.split(".")]
    while len(core) < 3: core.append(0)
    return core, pre
def pre_cmp(a, b):
    if not a and not b: return 0
    if not a: return 1
    if not b: return -1
    sa, sb = a.split("."), b.split(".")
    for x, y in zip(sa, sb):
        xn, yn = x.isdigit(), y.isdigit()
        if xn and yn:
            xi, yi = int(x), int(y)
            if xi != yi: return -1 if xi < yi else 1
        else:
            # 数值标识 < 字母数字标识
            if xn != yn: return -1 if xn else 1
            if x != y: return -1 if x < y else 1
    return 0 if len(sa) == len(sb) else (-1 if len(sa) < len(sb) else 1)
# 比较函数（max 用 cmp_to_key 包装）
import functools
def cmp(a, b):
    ca, pa = parse(a); cb, pb = parse(b)
    if ca != cb: return -1 if ca < cb else 1
    return pre_cmp(pa, pb)
m = max(tags, key=functools.cmp_to_key(cmp))
print(m)
'
}

# ---------- 判定目标 tag ----------
if [[ -z "$TARGET_TAG" ]]; then
  echo "… 正在从 api.github.com 自动判定 $REPO 最新 tag …" >&2
  TARGET_TAG="$(pick_latest_tag)"
fi

# --print-tag: 只输出 tag 到 stdout（其余提示走 stderr），不下载任何东西。
# CI 发布 job 用它拿「与官方同 tag」的 Release tag 名。
if [[ "${PRINT_TAG:-0}" == "1" ]]; then
  echo "$TARGET_TAG"
  exit 0
fi
echo "目标 tag: $TARGET_TAG"

# ---------- tag 卫生化：仅保留安全字符 ----------
SAFE_TAG="$(echo "$TARGET_TAG" | tr -cd 'A-Za-z0-9._-' )"
if [[ "$SAFE_TAG" != "$TARGET_TAG" ]]; then
  echo "✗ tag 含不合法字符，已拒绝: $TARGET_TAG" >&2
  exit 1
fi

TARGET="$SRC_DIR/$SAFE_TAG"
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  echo "✓ 已存在且非空，跳过（不覆盖）: $TARGET"
  exit 0
fi

WORK="$SRC_DIR/$TMP_PREFIX"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# ---------- 方法0: 本地 git 缓存增量拉取（首选） ----------
# 依据（2026-10-03 用户要求）：官方是 **git 仓库**，不该每次全量下快照；且**旧源码可复用**。
#   复用优先级：
#     ① 已有镜像 <SRC_DIR>/.cache/<repo>.git  → 直接 fetch（只下增量）
#     ② 无镜像但已有旧快照（浅克隆、带 .git）→ 就地当种子（补 origin 后 fetch）
#     ③ 都没有 → 建镜像 git clone --filter=blob:none --no-checkout（仅首次；blob 按需拉取）
#   出快照一律用 `git archive`：只落该 tag 的树，不二次克隆、不污染镜像工作区。
#   实测收益：换版下载量由 zipball 的 ~185MB 降到增量级（git 只传本地缺失的对象）。
CACHE_NAME="$(echo "$REPO" | tr '/' '-')"
CACHE_DIR="$SRC_DIR/.cache/$CACHE_NAME.git"
REPO_URL="${DS_FETCH_GIT_URL:-https://github.com/$REPO}"

cache_prepare_seed() {
  if [[ -d "$CACHE_DIR" ]]; then printf '%s' "$CACHE_DIR"; return 0; fi
  local d
  for d in "$SRC_DIR"/*/; do
    [[ -d "${d%/}/.git" ]] || continue
    printf '%s' "${d%/}"; return 0      # 复用旧快照当种子
  done
  mkdir -p "$SRC_DIR/.cache" 2>/dev/null || true
  echo "… 首次建立本地镜像（--filter=blob:none --no-checkout，blob 按需拉取）…" >&2
  if timeout 300 "$GIT_BIN" -c 'safe.directory=*' clone --filter=blob:none --no-checkout --quiet "$REPO_URL" "$CACHE_DIR" 2>/dev/null; then
    printf '%s' "$CACHE_DIR"
  fi
  return 0
}

SEED=""
[[ -n "$GIT_BIN" ]] && SEED="$(cache_prepare_seed)"
if [[ -n "$SEED" ]]; then
  # 复用旧快照时它可能没有 origin（实测 0.2.0 快照 remote/tags 都是空的）
  if "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" remote get-url origin >/dev/null 2>&1; then
    "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" remote set-url origin "$REPO_URL" 2>/dev/null || true
  else
    "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" remote add origin "$REPO_URL" 2>/dev/null || true
  fi
  echo "… 增量拉取 $SAFE_TAG（缓存: $SEED）…" >&2
  # --depth 1 + 显式 refspec：只要该 tag 的提交与树；已有对象 git 不会重下
  if "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" fetch --depth 1 --no-tags -v origin "refs/tags/$SAFE_TAG:refs/tags/$SAFE_TAG" 2>"$WORK/fetch.err" \
     || "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" fetch --depth 1 --no-tags -v origin "refs/tags/$SAFE_TAG" 2>>"$WORK/fetch.err"; then
    # 打印本次真实下载量（证据：增量而非全量）
    grep -oE "Receiving objects: *[0-9]+% \([0-9]+/[0-9]+\)[^,]*" "$WORK/fetch.err" | tail -1 | sed 's/^/    /' >&2 || true
    if "$GIT_BIN" -c 'safe.directory=*' -C "$SEED" archive --format=tar "$SAFE_TAG" 2>/dev/null | { mkdir -p "$TARGET" && tar -xf - -C "$TARGET"; }; then
      echo "✓ 已通过本地缓存增量拉取: $REPO@$SAFE_TAG → $TARGET"
      exit 0
    fi
    echo "… git archive 失败，继续回退 …" >&2
  else
    echo "… 缓存 fetch 失败（详见 $WORK/fetch.err），继续回退 …" >&2
  fi
fi

# ---------- 方法A: git clone（回退②，github 443 直连通时） ----------
GH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 https://github.com || true)"
CHOSEN="git clone"
if [[ -n "$GIT_BIN" ]] && [[ "$GH_CODE" != "000" ]]; then
  echo "… 尝试 git clone --depth 1（github 443 可达，code=$GH_CODE）…"
  if timeout 120 "$GIT_BIN" -c 'safe.directory=*' clone --depth 1 --branch "$SAFE_TAG" \
       "https://github.com/$REPO" "$WORK/clone" 2>/dev/null; then
    mv "$WORK/clone" "$TARGET"
    echo "✓ 已通过 git clone 拉取: $REPO@$SAFE_TAG → $TARGET"
    exit 0
  fi
  echo "… git clone 失败，回退到 API zipball 下载 …"
fi

# ---------- 方法B: API zipball 下载解压（回退，本机 github 443 不通走这里） ----------
CHOSEN="API zipball"
echo "… 通过 api.github.com 下载 zipball（$REPO@$SAFE_TAG）…"
ZIP="$WORK/head.zip"
# 加固：-f 失败即报错 + -C - 断点续传 + --retry 重试，慢/抖动网络不再因连接中断就失败
if ! curl -fL --retry 8 --retry-all-errors --retry-delay 3 -C - \
     --connect-timeout 15 -o "$ZIP" \
     "https://api.github.com/repos/$REPO/zipball/$SAFE_TAG" 2>"$WORK/curl.err"; then
  echo "✗ 下载 zipball 失败（详见 $WORK/curl.err）。" >&2
  exit 1
fi
if ! unzip -q -t "$ZIP" >/dev/null; then
  echo "✗ zip 完整性校验失败，下载不完整，请重试。" >&2
  exit 1
fi
if ! unzip -q "$ZIP" -d "$WORK/extract"; then
  echo "✗ 解压失败（zip 校验通过但解包异常）。" >&2
  exit 1
fi
INNER="$(find "$WORK/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -z "$INNER" ]] && { echo "✗ 解压后未找到源码目录。" >&2; exit 1; }
mv "$INNER" "$TARGET"
rm -f "$ZIP"

# ---------- 校验 ----------
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET")" ]]; then
  echo "✓ 完整下载完成: $REPO@$SAFE_TAG"
  echo "  方式: $CHOSEN"
  echo "  位置: $TARGET"
else
  echo "✗ 目标目录异常为空，下载可能不完整: $TARGET" >&2
  exit 1
fi