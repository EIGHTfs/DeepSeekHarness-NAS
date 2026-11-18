#!/bin/bash
# ⚠ 机制已更新（2026-10-03）：改为写 **pnpm-workspace.yaml 的 storeDir**（完整路径，不剥 /v11 段）。
#   原因：pnpm 11 不读 .npmrc 的 store-dir（实测写完 pnpm store path 仍是默认值）→ 旧实现等于没生效。
#   机制说明见 README「裁剪白名单」(#prune-whitelist)；权威实现见 build/start.sh.example 的 fix_pnpm_store_dir_one()。
# ============================================================
#  fix-pnpm-store.sh
#  修复 pnpm store 位置不匹配导致的插件安装失败
#  「ERR_PNPM_UNEXPECTED_STORE: Unexpected store location」
#
#  背景（2026-09-17 实测闭环）：
#    DSH 套件以 <包名> 用户运行，其 HOME 是 <套件根>/<包名>/home。
#    profile 的 node_modules 实际由这个 HOME 下的 store 链接而成：
#      <套件根>/<包名>/home/.local/share/pnpm/store/v11
#    但该 HOME 下没有 .npmrc，pnpm 遂退回默认 store 位置
#    （$HOME/.local/share/pnpm/store，或读不到 HOME 时的 /root 等）。
#    两者不一致 → pnpm 拒绝操作并直接退出，表现为：
#      · 插件市场安装任何插件都失败（报 UNEXPECTED_STORE）
#      · `dsh plugin --profile web add <源>` 失败
#      · 手动 `pnpm add` 失败
#    2026-09-15 的市场日志中 dsh-better-sidebar / dsh-theme-firefly
#    安装失败即此症，与具体插件无关。
#
#  本脚本：
#    1) 定位 profile node_modules 的**真实** store（读 .modules.yaml，
#       不猜测、不硬编码）——这是唯一权威来源
#    2) 把 store-dir 写进套件用户的 HOME/.npmrc（幂等：已有同值则跳过）
#    3) 以套件用户身份验证 pnpm 能读到该配置且 install 不再报错
#
# 【USAGE-BEGIN】
#  用法: ./fix-pnpm-store.sh [DSH_HOME] [选项]
#        缺省 DSH_HOME = <数据根>/<包名>/<版本>/.dsh（自动取最新版本目录）
#        若只给到实例目录，脚本自动补 .dsh
#  选项:
#    -d, --dry-run        只显示将改什么，不写入
#    --package <名>       套件包名（默认 DeepSeekHarness-NAS）
#    --pkg-root <目录>    平台套件根（默认 /var/packages；飞牛为 /var/apps）
#    --data-root <目录>   平台数据根（默认 /volume1/@appdata；飞牛为 /vol1/@appcenter）
#        后三项让同一份逻辑适用于别的套件，不必改脚本。
# 【USAGE-END】
#
#  注意：必须用 root 运行（要写套件用户 HOME）；脚本内部会 su 到
#        套件用户执行验证，因此 .npmrc 的属主是套件用户而非 root。
# ============================================================

set -u

DRY_RUN=0
DSH_HOME=""
# 包名与平台根目录都可覆盖：本脚本的逻辑与具体套件无关，别的套件同样适用。
#   --package    套件包名（决定默认的 data/appstore/packages 路径，默认本项目）
#   --pkg-root   平台套件根（群晖 /var/packages，飞牛 /var/apps）
#   --data-root  平台数据根（群晖 /volume1/@appdata，飞牛 /vol1/@appcenter）
PKG_NAME="${PKG_NAME:-DeepSeekHarness-NAS}"
PKG_ROOT_ARG=""
DATA_ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dry-run) DRY_RUN=1; shift ;;
    --package)    PKG_NAME="${2:?--package 需要一个包名}"; shift 2 ;;
    --package=*)  PKG_NAME="${1#*=}"; shift ;;
    --pkg-root)   PKG_ROOT_ARG="${2:?--pkg-root 需要一个目录}"; shift 2 ;;
    --pkg-root=*) PKG_ROOT_ARG="${1#*=}"; shift ;;
    --data-root)  DATA_ROOT_ARG="${2:?--data-root 需要一个目录}"; shift 2 ;;
    --data-root=*)DATA_ROOT_ARG="${1#*=}"; shift ;;
    -h|--help)
      # 标记必须在源码里拆成两段拼接：整串写进命令会让 sed 自己那行也匹配到开始标记，
      #   范围于是重新打开、一路打到文件末尾（实测踩过）。
      _b='【USAGE''-BEGIN】'; _e='【USAGE''-END】'
      sed -n "/${_b}/,/${_e}/p" "$0" | sed 's/^# \{0,1\}//' | grep -v 'USAGE-'
      exit 0 ;;
    *)            [ -z "$DSH_HOME" ] && DSH_HOME="$1"; shift ;;
  esac
done

# 平台路径单一出处（默认值即真实路径，可用环境变量/上面的参数覆盖）
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/platform-paths.sh"
[ -n "$PKG_ROOT_ARG" ] && PLATFORM_DSM_PKG_ROOT="$PKG_ROOT_ARG"
[ -n "$DATA_ROOT_ARG" ] && PLATFORM_DSM_APPDATA_ROOT="$DATA_ROOT_ARG"

# ── 定位 DSH_HOME ─────────────────────────────────────────────
if [ -z "$DSH_HOME" ]; then
  # 自动探测：<数据根>/<包名>/<版本>/.dsh（群晖与飞牛的数据根都试一遍）
  for base in "$PLATFORM_DSM_APPDATA_ROOT/$PKG_NAME" "$PLATFORM_FNOS_APPCENTER_ROOT/$PKG_NAME"; do
    [ -d "$base" ] || continue
    ver="$(ls -1 "$base" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -1)"
    [ -n "$ver" ] && [ -d "$base/$ver/.dsh" ] && { DSH_HOME="$base/$ver/.dsh"; break; }
  done
fi
# 允许只给实例目录
[ -n "$DSH_HOME" ] && [ ! -d "$DSH_HOME" ] && [ -d "$DSH_HOME/.dsh" ] && DSH_HOME="$DSH_HOME/.dsh"

if [ -z "$DSH_HOME" ] || [ ! -d "$DSH_HOME" ]; then
  echo "[!] 未找到 DSH_HOME（可用参数显式指定）" >&2
  exit 1
fi

PROFILE_DIR="$DSH_HOME/profiles/web"
MODULES_YAML="$PROFILE_DIR/node_modules/.modules.yaml"

echo "═══════════════════════════════════════════"
echo "  修复 pnpm store 位置不匹配"
echo "═══════════════════════════════════════════"
echo "  DSH_HOME: $DSH_HOME"
echo "  profile : $PROFILE_DIR"

# ── 定位套件用户与 HOME ───────────────────────────────────────
# 以 profile 目录的属主为准（就是运行 DSH 的那个用户），不硬编码用户名
PKG_USER="$(stat -c '%U' "$PROFILE_DIR" 2>/dev/null)"
[ -z "$PKG_USER" ] || [ "$PKG_USER" = "UNKNOWN" ] && PKG_USER="$PKG_NAME"

PKG_HOME=""
[ -d "$PLATFORM_DSM_PKG_ROOT/$PKG_NAME/home" ] && PKG_HOME="$PLATFORM_DSM_PKG_ROOT/$PKG_NAME/home"
[ -z "$PKG_HOME" ] && PKG_HOME="$(getent passwd "$PKG_USER" 2>/dev/null | cut -d: -f6)"

if [ -z "$PKG_HOME" ] || [ ! -d "$PKG_HOME" ]; then
  echo "[!] 未找到套件用户 HOME（用户: $PKG_USER）" >&2
  exit 1
fi

NPMRC="$PKG_HOME/.npmrc"
echo "  用户     : $PKG_USER"
echo "  HOME     : $PKG_HOME"
echo "  .npmrc   : $NPMRC"

# ── ① 读真实 store（唯一权威来源）────────────────────────────
if [ ! -f "$MODULES_YAML" ]; then
  echo "[!] 未找到 $MODULES_YAML" >&2
  echo "    请先在套件里启动一次 DSH，让依赖完成安装后再运行本脚本。" >&2
  exit 1
fi

STORE_DIR="$(grep -oE '"storeDir"[[:space:]]*:[[:space:]]*"[^"]+"' "$MODULES_YAML" 2>/dev/null \
  | head -1 | sed -E 's/.*"storeDir"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
# ⚠ **不要**剥掉 /v11 版本段：pnpm 11 读的是 pnpm-workspace.yaml 的 storeDir，需要**完整路径**。
#   旧实现剥段后写 .npmrc 的 store-dir —— 而 pnpm 11 根本不读 .npmrc 的该键（实测：写完
#   `pnpm store path` 仍返回默认值），等于整段没生效。

if [ -z "$STORE_DIR" ]; then
  echo "[!] 未能从 .modules.yaml 解析出 storeDir" >&2
  exit 1
fi
echo "  真实 store: $STORE_DIR  ← 来自 .modules.yaml"

# ── ② 写 pnpm-workspace.yaml 的 storeDir（幂等）────────────────────────
#   pnpm 11 从 pnpm-workspace.yaml 读 storeDir；.npmrc 的 store-dir 已不生效（实测）。
#   权威实现：build/start.sh.example 的 fix_pnpm_store_dir_one()（README #prune-whitelist）。
WS_YAML="$(dirname "$(dirname "$MODULES_YAML")")/pnpm-workspace.yaml"
WANT_LINE="storeDir: $STORE_DIR"
echo ""
if [ -f "$WS_YAML" ] && grep -qxF "$WANT_LINE" "$WS_YAML" 2>/dev/null; then
  echo "[√] pnpm-workspace.yaml 已是正确值，无需修改"
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] 将写入 $WS_YAML:"
    echo "          $WANT_LINE"
  else
    # 存在旧 storeDir 行先移除，避免多条冲突
    if [ -f "$WS_YAML" ]; then
      cp "$WS_YAML" "$WS_YAML.bak-$(date +%s)" 2>/dev/null
      grep -vE '^[[:space:]]*storeDir[[:space:]]*:' "$WS_YAML" > "$WS_YAML.tmp" 2>/dev/null
      mv "$WS_YAML.tmp" "$WS_YAML"
    fi
    printf '%s\n' "$WANT_LINE" >> "$WS_YAML"
    chown "$PKG_USER" "$WS_YAML" 2>/dev/null
    echo "[√] 已写入 $WS_YAML（属主 $PKG_USER）"
  fi
fi

# ── ③ 以套件用户身份验证 ────────────────────────────────────
# pnpm 入口与 node 都用共享库探测（随包 pnpm → PATH → corepack 缓存；node 走项目自备/PATH）
PNPM_MJS="$(resolve_pnpm_entry 2>/dev/null || true)"
NODE_BIN=""
for c in "$(platform_pkg_dest "$PKG_NAME")/bin/node" \
         "$PLATFORM_DSM_PKG_ROOT/$PKG_NAME/target/bin/node" \
         /usr/local/bin/node /usr/bin/node; do
  [ -n "$c" ] && [ -x "$c" ] && { NODE_BIN="$c"; break; }
done

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 跳过验证"
elif [ -n "$PNPM_MJS" ] && [ -n "$NODE_BIN" ]; then
  echo "[>] 验证（以 $PKG_USER 身份跑 pnpm install --lockfile-only）"
  OUT="$(su -s /bin/sh "$PKG_USER" -c \
    "cd '$PROFILE_DIR' && env HOME='$PKG_HOME' '$NODE_BIN' '$PNPM_MJS' install --lockfile-only 2>&1" 2>&1)"
  if echo "$OUT" | grep -q "UNEXPECTED_STORE"; then
    echo "[!] 仍报 UNEXPECTED_STORE："
    echo "$OUT" | tail -8
    exit 1
  elif echo "$OUT" | grep -q "EACCES"; then
    echo "[!] 权限错误（检查 $NPMRC 属主/权限）："
    echo "$OUT" | tail -8
    exit 1
  else
    echo "[√] 验证通过（无 UNEXPECTED_STORE / EACCES）"
    echo "$OUT" | tail -2 | sed 's/^/    /'
  fi
else
  echo "[!] 未找到 pnpm.mjs 或 node，跳过验证" >&2
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  修复完成"
echo "═══════════════════════════════════════════"
echo "  之后在插件市场或 dsh plugin add 安装插件应不再报 UNEXPECTED_STORE。"
echo "  若仍失败，请检查商店日志："
echo "    $PROFILE_DIR/.dsh-market/log.ndjson"
echo "═══════════════════════════════════════════"
