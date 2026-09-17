#!/bin/bash
# ============================================================
#  fix-pnpm-store.sh
#  修复 pnpm store 位置不匹配导致的插件安装失败
#  「ERR_PNPM_UNEXPECTED_STORE: Unexpected store location」
#
#  背景（2026-09-17 实测闭环）：
#    DSH 套件以 `DeepSeekHarness-NAS` 用户运行，其 HOME 是
#    /var/packages/DeepSeekHarness-NAS/home。profile 的 node_modules
#    实际由这个 HOME 下的 store 链接而成：
#      /var/packages/DeepSeekHarness-NAS/home/.local/share/pnpm/store/v11
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
#  用法: ./fix-pnpm-store.sh [DSH_HOME]
#        缺省 DSH_HOME = /volume1/@appdata/DeepSeekHarness-NAS/<版本>/.dsh
#        若只给到实例目录，脚本自动补 .dsh
#  -d / --dry-run : 只显示将改什么，不写入
#
#  注意：必须用 root 运行（要写套件用户 HOME）；脚本内部会 su 到
#        套件用户执行验证，因此 .npmrc 的属主是套件用户而非 root。
# ============================================================

set -u

DRY_RUN=0
for a in "$@"; do
  [ "$a" = "-d" ] || [ "$a" = "--dry-run" ] && DRY_RUN=1
done

# ── 定位 DSH_HOME ─────────────────────────────────────────────
DSH_HOME="${1:-}"
[ "${DSH_HOME}" = "-d" ] || [ "${DSH_HOME}" = "--dry-run" ] && DSH_HOME=""

if [ -z "$DSH_HOME" ]; then
  # 自动探测：/volume1/@appdata/DeepSeekHarness-NAS/<版本>/.dsh
  for base in /volume1/@appdata/DeepSeekHarness-NAS /vol1/@appdata/DeepSeekHarness-NAS; do
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
[ -z "$PKG_USER" ] || [ "$PKG_USER" = "UNKNOWN" ] && PKG_USER="DeepSeekHarness-NAS"

PKG_HOME=""
[ -d "/var/packages/DeepSeekHarness-NAS/home" ] && PKG_HOME="/var/packages/DeepSeekHarness-NAS/home"
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
# .modules.yaml 里可能写 .../store/v11，.npmrc 的 store-dir 要的是 .../store（不带版本段）
STORE_DIR="${STORE_DIR%/v[0-9]*}"

if [ -z "$STORE_DIR" ]; then
  echo "[!] 未能从 .modules.yaml 解析出 storeDir" >&2
  exit 1
fi
echo "  真实 store: $STORE_DIR  ← 来自 .modules.yaml"

# ── ② 写 .npmrc（幂等）──────────────────────────────────────
WANT_LINE="store-dir=$STORE_DIR"
echo ""
if [ -f "$NPMRC" ] && grep -qxF "$WANT_LINE" "$NPMRC" 2>/dev/null; then
  echo "[√] .npmrc 已是正确值，无需修改"
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] 将写入 $NPMRC:"
    echo "          $WANT_LINE"
  else
    # 存在旧的 store-dir/store.path 行先移除，避免多条冲突
    if [ -f "$NPMRC" ]; then
      cp "$NPMRC" "$NPMRC.bak-$(date +%s)" 2>/dev/null
      grep -vE '^[[:space:]]*(store-dir|store\.path)[[:space:]]*=' "$NPMRC" > "$NPMRC.tmp" 2>/dev/null
      mv "$NPMRC.tmp" "$NPMRC"
    fi
    printf '%s\n' "$WANT_LINE" >> "$NPMRC"
    chown "$PKG_USER" "$NPMRC" 2>/dev/null
    chmod 600 "$NPMRC" 2>/dev/null
    echo "[√] 已写入 $NPMRC（属主 $PKG_USER）"
  fi
fi

# ── ③ 以套件用户身份验证 ────────────────────────────────────
PNPM_MJS=""
for c in /var/packages/DeepSeekHarness-NAS/target/pnpm/dist/pnpm.mjs \
         /volume1/@appstore/DeepSeekHarness-NAS/pnpm/dist/pnpm.mjs; do
  [ -f "$c" ] && { PNPM_MJS="$c"; break; }
done
NODE_BIN=""
for c in /var/packages/DeepSeekHarness-NAS/target/bin/node /usr/local/bin/node /usr/bin/node; do
  [ -x "$c" ] && { NODE_BIN="$c"; break; }
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
