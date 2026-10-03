#!/bin/bash
# ==============================================================================
# 构建环境自动准备（幂等）· scripts/prepare-build-env.sh
#
# 【为什么需要它】本项目的构建前置**大多不在 git 里**（是下载/生成产物）：
#   · 随包 node      tools/node-dist/node-v*/bin/node
#   · 官方预编译 native 产物  @deepseek-ai/node-addon-system-<host>/bin/glibc/system.node
#   · 官方源码快照    src/deepseek-ai/dsh-<version>
#   干净 clone / 工作区被清空后，这些缺失会让构建以**难懂的错误**失败，例如：
#     · [pnpm-shim] 找不到可执行的 node      （node 缺失）
#     · Error: spawnSync cc ENOENT          （无 C 编译器，且没找到可复用的预编译产物）
#     · git fetch 卡死 150s 零对象           （193 到 GitHub 的 git 协议不通）
#   本脚本把它们一次性备齐，且**只做幂等新增**，不删除任何东西。
#
# 【用户纪律】工作区挂载由用户/正规机制负责 —— 本脚本**只检测并报告** noexec 等
#   挂载问题，**绝不执行 mount**。
#
# 用法:
#   bash scripts/prepare-build-env.sh                 # 全部检查并补齐
#   bash scripts/prepare-build-env.sh --check         # 只检查不下载
#   DSH_VERSION=0.2.1-alpha.1 bash scripts/prepare-build-env.sh
# ==============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_VER="${NODE_VER:-22.23.3}"
DSH_VERSION="${DSH_VERSION:-0.2.1-alpha.1}"
NPMMIRROR="${NPMMIRROR:-https://npmmirror.com}"
NPM_REG="${NPM_REG:-https://registry.npmmirror.com}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.com}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
miss() { echo "  ✗ $*"; }
info() { echo "▶ $*"; }

echo "═══ 构建环境准备 ═══"
echo "  工作区 : $WS"
echo "  node   : v$NODE_VER    dsh: $DSH_VERSION    check-only: $CHECK_ONLY"
echo

# ── 0) 工作区挂载可执行性（只报告，不 mount —— 用户纪律）──────────────
info "0) 工作区挂载可执行性"
case "$WS" in
  /volume*/@appdata/*) MOUNT_OPTS="$(mount 2>/dev/null | awk -v p="$WS" 'index($0,p)==1 {print; exit}')" ;;
  *)                   MOUNT_OPTS="$(mount 2>/dev/null | awk -v p="$WS" 'index($0,p)==1 {print; exit}')" ;;
esac
if echo "$MOUNT_OPTS" | grep -q noexec; then
  warn "当前路径所在挂载带 noexec（不可执行）→ 构建请改用不带 noexec 的挂载点"
  warn "  当前: $(echo "$MOUNT_OPTS" | cut -c1-110)"
  warn "  （本脚本不会自行 mount —— 挂载由你/正规机制负责）"
else
  ok "未检测到 noexec（或无法判定）"
fi

# ── 1) 随包 node ──────────────────────────────────────────────────────
info "1) 随包 node（tools/node-dist/node-v*/bin/node）"
NODE_BIN="$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1)"
if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ]; then
  ok "已就位: $NODE_BIN ($("$NODE_BIN" -v 2>/dev/null))"
elif [ "$CHECK_ONLY" = "1" ]; then
  miss "缺失（--check 模式不下载）"
else
  warn "缺失 → 从 $NPMMIRROR 下载 v$NODE_VER"
  mkdir -p "$WS/tools/node-dist" && cd /tmp || exit 1
  if curl -sL --max-time 600 -o /tmp/dsh-node.txz \
       "$NPMMIRROR/mirrors/node/v$NODE_VER/node-v$NODE_VER-linux-x64.tar.xz"; then
    tar -xJf /tmp/dsh-node.txz -C "$WS/tools/node-dist" --no-same-owner 2>/dev/null
    NODE_BIN="$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1)"
    [ -n "$NODE_BIN" ] && ok "已下载: $NODE_BIN" || miss "下载后仍找不到 node"
  else
    miss "下载失败（检查网络/镜像）"
  fi
fi

# ── 2) 项目 pnpm ──────────────────────────────────────────────────────
info "2) 项目自带 pnpm（tools/pnpm/bin/pnpm.mjs）"
if [ -f "$WS/tools/pnpm/bin/pnpm.mjs" ] || [ -f "$WS/tools/pnpm/bin/pnpm.cjs" ]; then
  ok "已就位（tools/pnpm）"
else
  miss "缺失 tools/pnpm（属项目文件，应由 git 提供；请检查 checkout 完整性）"
fi

# ── 3) 官方预编译 native 产物（cc 替身复用来源）────────────────────────
#   cc-shim 的三个来源之一：$WS/build/master-build/**/node-addon-system-<host>/bin/glibc/system.node
#   缺它且宿主无 C 编译器时，native 步骤会以 `spawnSync cc ENOENT` 失败。
info "3) 官方预编译 native 产物（node-addon-system-<host>）"
HOST="linux-x64"
FOUND="$(find "$WS/build/master-build" -maxdepth 9 -path "*node-addon-system-$HOST/bin/glibc/system.node" 2>/dev/null | head -1)"
if [ -n "$FOUND" ]; then
  ok "已就位: $FOUND"
elif [ "$CHECK_ONLY" = "1" ]; then
  miss "缺失（--check 模式不下载）"
else
  PKG="@deepseek-ai/node-addon-system-$HOST"
  warn "缺失 → 从 $NPM_REG 下载 $PKG"
  VER="$(curl -s --max-time 60 "$NPM_REG/$PKG" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('dist-tags',{}).get('latest',''))" 2>/dev/null)"
  if [ -n "$VER" ]; then
    DST="$WS/build/master-build/prebuilt/node_modules/$PKG"
    mkdir -p "$DST"
    if curl -sL --max-time 300 -o /tmp/dsh-nas.tgz "$NPM_REG/$PKG/-/node-addon-system-$HOST-$VER.tgz"; then
      tar -xzf /tmp/dsh-nas.tgz -C "$DST" --strip-components=1 --no-same-owner 2>/dev/null
      [ -f "$DST/bin/glibc/system.node" ] && ok "已下载: $DST/bin/glibc/system.node (v$VER)" || miss "解包后未找到 system.node"
    else
      miss "下载失败"
    fi
  else
    miss "版本查询失败（$PKG）"
  fi
fi

# ── 4) 官方源码快照 ───────────────────────────────────────────────────
info "4) 官方源码快照（src/deepseek-ai/dsh-[$DSH_VERSION 或 v$DSH_VERSION]）"
# 目录名兼容两种写法：项目惯例是 dsh-v<ver>（带 v），也兼容 dsh-<ver>
SRC="$(ls -d "$WS"/src/deepseek-ai/dsh-v"$DSH_VERSION" 2>/dev/null | head -1)"
[ -n "$SRC" ] || SRC="$(ls -d "$WS"/src/deepseek-ai/dsh-"$DSH_VERSION" 2>/dev/null | head -1)"
[ -n "$SRC" ] || SRC="$WS/src/deepseek-ai/dsh-v$DSH_VERSION"
if [ -f "$SRC/package.json" ]; then
  ok "已就位: $SRC"
elif [ "$CHECK_ONLY" = "1" ]; then
  miss "缺失（--check 模式不下载）"
else
  warn "缺失 → 经 $GH_PROXY 拉 tag 包 dsh-v$DSH_VERSION（git 协议在本环境常不通）"
  mkdir -p "$SRC"
  if curl -sL --max-time 900 -o /tmp/dsh-src.tgz \
       "$GH_PROXY/https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/dsh-v$DSH_VERSION.tar.gz"; then
    tar -xzf /tmp/dsh-src.tgz -C "$SRC" --strip-components=1 --no-same-owner 2>/dev/null
    [ -f "$SRC/package.json" ] && ok "已下载: $SRC" || miss "解包后未找到 package.json"
  else
    miss "下载失败"
  fi
fi

echo
echo "═══ 准备完成（缺项请按上面 ✗/⚠ 处理；本脚本只新增、不删除，也不执行 mount）═══"
