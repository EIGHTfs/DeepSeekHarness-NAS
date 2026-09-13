#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — npm 装包版应用体构建（FPK 双链路之一）
#===============================================================================
# 【与本仓库其他脚本的关系】
#   build-common.sh  源码 monorepo 编译 → target（SPK/FPK 源码链路共用；SPK 已成功，勿动）
#   build-npm-app.sh 【本脚本】npm 装官方包 → app_root（FPK npm 链路；独立新增，不影响 SPK）
#   build-fpk.sh     消费 target 或 app_root → 飞牛 .fpk（加 --npm 走本脚本产物）
#
# 依据:10000ge10000/deepseek-harness-fpk 的 npm 装包方案实测（2026-09-13，
#   产物 100.5MiB vs 源码 173MB；构建 ~12min vs ~20min；本机 fnOS 装成 running）。
#   我们不照抄对方的 runner.js（依赖其品牌 patch/settings），只复用「npm 装包 + 自带 node/pnpm」
#   的 app_root 组装思路，start.sh 一律用我们自己的母版（入口收敛 + token 免密）。
#
# 用法:
#   ./build-npm-app.sh [VERSION] [NODE_VERSION]
#     VERSION      官方 dsh 版本（缺省自动解析 npm dist-tags.next）
#     NODE_VERSION node 版本（缺省 24.4.0）
#   产物: build/spk-build/npm-app-VERSION/  app_root/  +  npm-meta.env
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/build-config.yaml"

# ── 工作区分类目录（与 build-common.sh 一致） ──
D_BUILD="${D_BUILD:-$WS/build}"
D_STAGING="${D_STAGING:-$D_BUILD/staging}"

# ── 从 build-config.yaml 读 ports 段（FPK 用 defaults/fpk: 通用 3080 段） ──
eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f) or {}
defaults = cfg.get('defaults') or {}
fpk = cfg.get('fpk') or {}
for k, v in {**defaults, **fpk}.items():
    print(f'CFG_{k.upper()}=\"{v}\"')
" 2>/dev/null || true)"
APP_NAME="${CFG_APPNAME:-DeepSeekHarness-NAS}"
APP_ID="$(echo "$APP_NAME" | tr -d -- '-_')"
APP_NAME_LOWER="$(echo "$APP_NAME" | tr 'A-Z' 'a-z')"
FPK_PROXY_PORT="${CFG_PROXY_PORT:-3080}"
FPK_DSH_PORT="${CFG_DSH_PORT:-3081}"
FPK_CONTAINER_PORT="${CFG_CONTAINER_PORT:-3082}"

# ── 参数 ──
VERSION="${1:-}"
NODE_VERSION="${2:-24.4.0}"
if [ -z "$VERSION" ] || [ "$VERSION" = "next" ]; then
  # 自动解析官方 npm next 版本（与 10000ge10000 resolve-version.sh 同思路）
  VERSION="$(npm view @deepseek-ai/dsh dist-tags.next 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
  echo "✗ 无法解析 @deepseek-ai/dsh 版本（网络不可达？）" >&2
  echo "  可显式传参: ./build-npm-app.sh 0.1.5-rc.2" >&2
  exit 1
fi
echo "══════ npm 装包构建 dsh@${VERSION} (Node ${NODE_VERSION}) ══════"

# ── 工作目录（版本隔离，永久缓存：node 运行时 / 装好的 node_modules 都不删，git 已忽略） ──
NPM_BUILD="$(cd "$D_BUILD/spk-build" && pwd)/npm-app-${VERSION}"
APP_ROOT="$NPM_BUILD/app_root"
NODE_DIR="$NPM_BUILD/node-v${NODE_VERSION}"
DSH_WEB="$NODE_DIR/dsh-web"
mkdir -p "$APP_ROOT/bin" "$NODE_DIR"

# ── 1. Node 运行时（缓存到版本目录，重复构建不重下） ──
NODE_ARCHIVE="node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  echo "▶ 下载 Node ${NODE_VERSION}..."
  curl -fL --retry 3 --connect-timeout 8 --max-time 180 -o "/tmp/${NODE_ARCHIVE}" "$NODE_URL"
  tar -xJf "/tmp/${NODE_ARCHIVE}" -C "$NODE_DIR" --strip-components=1
  rm -f "/tmp/${NODE_ARCHIVE}"
fi
export PATH="$NODE_DIR/bin:$PATH"
cp "$NODE_DIR/bin/node" "$APP_ROOT/bin/node"
chmod +x "$APP_ROOT/bin/node"

# ── 2. npm 装 @deepseek-ai/dsh（幂等：已装同版本则跳过，node_modules 永久保留复用） ──
_DSH_PKG="$DSH_WEB/node_modules/@deepseek-ai/dsh/package.json"
_NEED_INSTALL=1
if [ -f "$_DSH_PKG" ] && grep -q "\"version\":\s*\"${VERSION}\"" "$_DSH_PKG"; then
  _NEED_INSTALL=0
  echo "⏭ dsh@${VERSION} 已装于 $DSH_WEB，跳过 npm install"
fi
if [ "$_NEED_INSTALL" = "1" ]; then
  echo "▶ npm install @deepseek-ai/dsh@${VERSION}（扁平 node_modules，无 workspace 软链；装完永久保留）"
  (
    cd "$DSH_WEB" && npm init -y >/dev/null 2>&1 || true
    MAX=3; TRY=0; OK=false
    while [ $TRY -lt $MAX ]; do
      TRY=$((TRY+1))
      if node "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" install \
          "@deepseek-ai/dsh@${VERSION}" --omit=dev --no-audit --no-fund --prefer-online; then
        OK=true; break
      fi
      echo "  ⚠ npm install 失败 (尝试 $TRY/$MAX)"; sleep 5
    done
    [ "$OK" = true ] || { echo "✗ npm install @deepseek-ai/dsh@${VERSION} 失败" >&2; exit 1; }
  )
fi
cp -a "$DSH_WEB/node_modules" "$APP_ROOT/node_modules"
cp "$DSH_WEB/package.json" "$APP_ROOT/package.json" 2>/dev/null || true

# ── 3. 随包 pnpm（DSH plugin 子命令直接执行 pnpm；用我们自带的 tools/pnpm） ──
echo "▶ 随包 pnpm（tools/pnpm，$(node "$WS/tools/pnpm/bin/pnpm.mjs" --version 2>/dev/null || echo unknown)）"
mkdir -p "$APP_ROOT/tools"
cp -a "$WS/tools/pnpm/." "$APP_ROOT/tools/pnpm/"
# bin/pnpm 包装器（node 跑 pnpm.mjs，路径与包无关）
cat > "$APP_ROOT/bin/pnpm" <<'PNPM_WRAP'
#!/bin/bash
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${BIN_DIR}/.." && pwd)"
exec "${BIN_DIR}/node" "${APP_DIR}/tools/pnpm/bin/pnpm.mjs" "$@"
PNPM_WRAP
chmod +x "$APP_ROOT/bin/pnpm"

# ── 4. dsh CLI 包装器（SSH 下直接 dsh 可用；与 SPK 的软链思路一致但包内自包含） ──
cat > "$APP_ROOT/bin/dsh" <<'DSH_WRAP'
#!/bin/bash
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${BIN_DIR}/.." && pwd)"
export PATH="${BIN_DIR}:${PATH}"
exec "${BIN_DIR}/node" "${APP_DIR}/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
DSH_WRAP
chmod +x "$APP_ROOT/bin/dsh"

# ── 5. start.sh（我们自己的母版 → FPK 端口段; detect_entry 已兼容 npm 布局） ──
echo "▶ 生成 start.sh（端口 ${FPK_PROXY_PORT}/${FPK_DSH_PORT}/${FPK_CONTAINER_PORT}）"
sed -e "s|__PROXY_PORT__|${FPK_PROXY_PORT}|g" \
    -e "s|__DSH_PORT__|${FPK_DSH_PORT}|g" \
    -e "s|__CONTAINER_PORT__|${FPK_CONTAINER_PORT}|g" \
    -e "s|__APP_NAME__|${APP_NAME}|g" \
    -e "s|__APP_ID__|${APP_ID}|g" \
    "$WS/scripts/start.sh.example" > "$APP_ROOT/bin/start.sh"
chmod +x "$APP_ROOT/bin/start.sh"
if grep -q "__PROXY_PORT__\|__DSH_PORT__\|__CONTAINER_PORT__\|__APP_NAME__\|__APP_ID__" "$APP_ROOT/bin/start.sh"; then
  echo "[!] start.sh 占位符未全部替换" >&2; exit 1
fi

# ── 6. 元数据（build-fpk.sh --npm source 本文件） ──
cat > "$NPM_BUILD/npm-meta.env" <<EOF
# 由 build-npm-app.sh 生成（$(date '+%Y-%m-%d %H:%M:%S')）
APP_NAME='${APP_NAME}'
APP_ID='${APP_ID}'
APP_NAME_LOWER='${APP_NAME_LOWER}'
PKG_VER='${VERSION}'
FPK_VERSION='${VERSION}'
SPK_VERSION="$(echo "${VERSION}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "$VERSION")"
NODE_VERSION='${NODE_VERSION}'
APP_ROOT='${APP_ROOT}'
EOF

echo ""
echo "════════════════════════════════════════════════"
echo "✅ npm 装包应用体构建完成"
echo "  dsh     : @deepseek-ai/dsh@${VERSION}"
echo "  node    : v${NODE_VERSION}"
echo "  node_modules: $(du -sh "$APP_ROOT/node_modules" 2>/dev/null | cut -f1)"
echo "  app_root: $APP_ROOT"
echo "  端口    : $FPK_PROXY_PORT / $FPK_DSH_PORT / $FPK_CONTAINER_PORT"
echo "  接下来  : ./build-fpk.sh --npm 用本产物组装 fpk"
echo "════════════════════════════════════════════════"