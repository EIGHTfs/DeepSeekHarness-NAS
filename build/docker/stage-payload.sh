#!/bin/bash
# stage-payload.sh —— 为 Docker 镜像准备载荷：补齐 start.sh 并做入场校验。
#
# 为什么需要这一步：
#   start.sh **不在 build-common 的 target 产物里** —— 它由打包器在出包时调用
#   gen_start_sh() 生成（SPK/FPK 各自生成一份注入好端口的版本）。镜像若直接复制 target，
#   容器启动就会 `./start.sh: No such file or directory`（CI run #4 实测就是这么挂的）。
#   这里用**同一个** gen_start_sh() 生成，端口取与套件一致的 30800/30801/30802，
#   避免再写一套渲染逻辑。
#
# 用法：stage-payload.sh <target目录> [proxy端口] [dsh端口] [容器端口]
set -euo pipefail

TARGET_DIR="${1:?用法: stage-payload.sh <target目录> [proxy端口] [dsh端口] [容器端口]}"
PROXY_PORT="${2:-30800}"
DSH_PORT="${3:-30801}"
CONTAINER_PORT="${4:-30802}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$ROOT/build/config/build-config.yaml"
BUILD_LIB="$ROOT/build/build-lib.sh"

[ -d "$TARGET_DIR" ] || { echo "✗ 载荷目录不存在: $TARGET_DIR" >&2; exit 1; }
[ -f "$BUILD_LIB" ] || { echo "✗ 缺少公共函数库: $BUILD_LIB" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "✗ 缺少构建配置: $CONFIG" >&2; exit 1; }

# 从 defaults 段读扁平键（不引 python，保持脚本零依赖；与 pack-spk 同源同一份 yaml）
read_cfg() {
  awk -v key="$1:" '$1 == key { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print; exit }' "$CONFIG"
}

APPNAME="$(read_cfg appname)"
BRAND_NAME="$(read_cfg brand_name)"; [ -n "$BRAND_NAME" ] || BRAND_NAME="$APPNAME"
DISPLAY_NAME="$(read_cfg display_name)"
DESC_SHORT="$(read_cfg desc_short)"
VERSION_ORDER="$(read_cfg brand_version_order)"; [ -n "$VERSION_ORDER" ] || VERSION_ORDER="dsh,npm"
[ -n "$APPNAME" ] || { echo "✗ build-config.yaml 里没有 appname" >&2; exit 1; }

# 版本号：镜像里用于 FPK 口径兜底（SPK 用 INFO 版本），拿不到就留空，由 start.sh 自行解析
PKG_VER="$(grep -m1 '^PKG_VER=' "$(dirname "$TARGET_DIR")/build-meta.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'" || true)"

# shellcheck source=../../build/build-lib.sh
. "$BUILD_LIB"

echo "═══ 生成 start.sh（端口 ${PROXY_PORT}/${DSH_PORT}/${CONTAINER_PORT}）═══"
APP_NAME="$APPNAME" \
APP_ID="${APPNAME//-/}" \
CFG_BRAND_NAME="$BRAND_NAME" \
CFG_BRAND_VERSION_ORDER="$VERSION_ORDER" \
CFG_TITLE="$DISPLAY_NAME" \
CFG_DESC_SHORT="$DESC_SHORT" \
FPK_VERSION="$PKG_VER" \
BUILD_ROOT="$ROOT/build" \
  gen_start_sh "$TARGET_DIR/start.sh" "$PROXY_PORT" "$DSH_PORT" "$CONTAINER_PORT" "$DESC_SHORT"

chmod +x "$TARGET_DIR/start.sh"

# 入场校验：缺文件或占位符没替换干净，直接在构建期失败（别等容器里运行才发现）
[ -s "$TARGET_DIR/start.sh" ] || { echo "✗ start.sh 生成失败" >&2; exit 1; }
LEFTOVER="$(grep -oE '__[A-Z0-9]+(_[A-Z0-9]+)*__' "$TARGET_DIR/start.sh" 2>/dev/null \
  | grep -vE '^__(DSH_TRANSPORT|DSH_FILE_UPLOAD)__$' | sort -u || true)"
if [ -n "$LEFTOVER" ]; then
  echo "✗ start.sh 里有未替换的占位符：" >&2
  echo "$LEFTOVER" | sed 's/^/   /' >&2
  exit 1
fi
bash -n "$TARGET_DIR/start.sh" || { echo "✗ start.sh 语法检查未通过" >&2; exit 1; }
echo "✓ start.sh 就绪（$(grep -c '' "$TARGET_DIR/start.sh") 行，端口 ${PROXY_PORT}/${DSH_PORT}/${CONTAINER_PORT}）"
