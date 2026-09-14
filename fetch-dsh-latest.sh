#!/usr/bin/env bash
#
# fetch-dsh-latest.sh —— 一键拉取 DSH（DeepSeek Harness）官方最新版源码到 src/deepseek-ai/{tag}
#
# 用法:
#   ./fetch-dsh-latest.sh                        # 拉取官方最新 tag
#   ./fetch-dsh-latest.sh --tag dsh-v0.1.5-rc.2  # 指定某 tag（不自动判定最新）
#   ./fetch-dsh-latest.sh --repo owner/name      # 指定官方仓库（默认 deepseek-ai/deepseek-harness）
#   ./fetch-dsh-latest.sh --src-dir DIR          # 指定存放目录（默认 <脚本目录>/src/deepseek-ai）
#
# 策略:
#   版本: 从 GitHub 拉取全部 tags，用严格 semantic version(含 pre-release)比较，自动选最高 tag。
#   通道: 版本信息一律走 api.github.com；下载优先 git clone(github 443 通时)，不通/失败自动
#         回退到 api/zipball 下载解压。
#   去重: 目标 src/deepseek-ai/{tag} 目录已存在且非空 → 跳过不覆盖，重复运行不重复下载。
#
set -euo pipefail

# ---------- 定位脚本目录（供 src 目录推断，兼容任意 CWD 调用） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 默认与可配置项（可用命令行参数覆盖，不硬编码场景外路径） ----------
DEFAULT_REPO="deepseek-ai/deepseek-harness"
DEFAULT_SRC="$SCRIPT_DIR/src/deepseek-ai"
TMP_PREFIX=".dsh-fetch-$$"
TARGET_TAG=""          # 空 = 自动判定最新
PRINT_TAG=0            # --print-tag: 只打印 tag 不下载（CI 发布用）

usage() {
  sed -n '2,12p' "$0"
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
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

# ---------- 确定存放目录 ----------
[[ "$SRC_DIR" == "$DEFAULT_SRC" ]] && SRC_DIR="$SCRIPT_DIR/src/deepseek-ai"
mkdir -p "$SRC_DIR"

# ---------- 利用 python3 做严格 semver 比较并选出最高 tag（含 pre-release） ----------
pick_latest_tag() {
  TAGS_JSON="$(curl -s --connect-timeout 8 --max-time 20 \
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

# ---------- 方法A: git clone（优先，github 443 直连通时） ----------
GH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 https://github.com || true)"
CHOSEN="git clone"
if [[ "$GH_CODE" != "000" ]]; then
  echo "… 尝试 git clone --depth 1（github 443 可达，code=$GH_CODE）…"
  if timeout 120 git clone --depth 1 --branch "$SAFE_TAG" \
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