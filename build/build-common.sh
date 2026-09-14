#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — 公共预编译脚本（黑白名单筛选 + 源码预编译 → target）
#===============================================================================
# 【三脚本分工】2026-09-13 从原 build.sh（spk+fpk 混合 1216 行）拆分：
#   build-common.sh  公共：pnpm install + pnpm build + 黑白名单裁剪 → target 整树
#   build-spk.sh     群晖 .spk 打包（消费 target；无参数，端口/名字读 build-config.yaml）
#   build-fpk.sh     飞牛 .fpk 打包（消费 target；无参数，端口/名字读 build-config.yaml）
#
# 用法:
#   ./build-common.sh [SRC] [SKIP_BUILD]
#
# 参数（均可省略）:
#   1. SRC         源码目录（缺省=自动扫描 src/deepseek-ai/deepseek-harness-master
#                  或 spk-build/master-build）
#   2. SKIP_BUILD  1=复用已有完整 target（不重新构建；缺省=0 全量构建）
#
# 打包模式：唯一模式 = 预构建产物包（装完即用）
#   - 本地 pnpm install + pnpm build 生成全部构建产物（apps/cli/lib、apps/web/dist 等）
#   - 裁剪段删除：非目标平台二进制 / devDependencies（含传递依赖，清单动态读根 package.json）
#     / claude-agent-sdk+codex / packages|apps 的 src / docs / benchmarks / native
#   - 保留：bin/node + bin/dsh + bin/pnpm + 随包 pnpm + 各包 lib/dist 产物 + 运行时 node_modules
#   - 装完即用，无首启构建（首启构建逻辑已抽离 scripts/first-build-logic.sh 留档）；
#     start.sh 由 build-spk.sh / build-fpk.sh 各自按端口段生成（本脚本不生成）
#
# 产物:
#   target 整树       build/spk-build/build-<SPK_VERSION>/target（编译+裁剪后装包内容）
#   build-meta.env    同级 build-meta.env（APP_NAME/PKG_VER/SPK_VERSION/FPK_VERSION/DESC/COMMIT）
#                     —— spk/fpk 打包脚本 source 它获取元数据（单一真源）
#
# 之后:
#   ./build-spk.sh    → build/staging/<APP_NAME>_x86_64-<SPK_VERSION>.spk
#   ./build-fpk.sh    → build/staging/<APP_NAME>_x86-<FPK_VERSION>.fpk
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"              # 工作区根（脚本在 build/ 子目录）
CONFIG_FILE="$SCRIPT_DIR/build-config.yaml"     # 配置文件在 build 目录内
# 构建中间产物放 assets/（rw 工作区内），避免写到 /vol2 只读挂载
PNPM_STORE="${PNPM_STORE_DIR:-$WS/assets/pnpm-store}"
NPM_CACHE="${npm_config_cache:-$WS/assets/pnpm-cache}"
PNPM_BIN="$WS/tools/pnpm/bin/pnpm.mjs"  # 强制用项目自带 pnpm（tools/pnpm，不用系统自带）
PNPM_BIN_DIR="$WS/tools/pnpm/bin"
NODE_SRC="${NODE_SRC:-/usr/bin/node}"          # 打包进应用的 node 二进制

# ── 工作区分类目录（全部可用环境变量覆盖，默认以脚本所在目录为根） ──
D_SRC="${D_SRC:-$WS/src}"
D_ASSETS="${D_ASSETS:-$WS/build}"
D_BUILD="${D_BUILD:-$WS/build}"
D_REL="${D_REL:-$WS/release}"
D_STAGING="${D_STAGING:-$D_BUILD/staging}"
D_TOOLS="${D_TOOLS:-$WS/tools}"
D_DOCS="${D_DOCS:-$WS/docs}"
D_SCRIPTS="${D_SCRIPTS:-$WS/scripts}"

for _d in "$D_SRC" "$D_ASSETS" "$D_BUILD" "$D_REL" "$D_STAGING" "$D_TOOLS" "$D_DOCS" "$D_SCRIPTS"; do
  mkdir -p "$_d" 2>/dev/null || { echo "[!] 无法创建目录: $_d" >&2; exit 1; }
done
mkdir -p "$PNPM_STORE" "$NPM_CACHE"

# ----------------------------------------------------------------------------
# build-config.yaml 解析（公共段只要 defaults；端口在 spk/fpk 各自脚本解析）
# ----------------------------------------------------------------------------
_CFG_APPNAME="DeepSeekHarness-NAS"
if [ -f "$CONFIG_FILE" ]; then
  eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f) or {}
defaults = cfg.get('defaults') or {}
for k, v in defaults.items():
    print(f'_CFG_{k.upper()}=\"{v}\"')
" 2>/dev/null || true)"
fi

# --- 参数（精简：SRC / SKIP_BUILD）-----------------------------------------
SRC="${1:-}"
if [ -z "$SRC" ]; then
  # 通配扫描 src/deepseek-ai/*（不硬编码版本目录名），其次 spk-build/master-build
  for cand in "$D_SRC"/deepseek-ai/* "$D_BUILD/spk-build/master-build"; do
    if [ -f "$cand/package.json" ] && [ -d "$cand/apps/cli" ]; then
      SRC="$cand"; break
    fi
  done
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/package.json" ]; then
  echo "✗ 未找到源码目录。用法: $0 [SRC] [SKIP_BUILD]" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"
SKIP_BUILD="${2:-0}"
# 分阶段构建门控：all | install | build | prune（CI 把长步骤拆成 3 个独立 step，
# 靠 step 结论定位死点；分阶段时复用已有 WORK，不清不删）
BUILD_STAGE="${BUILD_STAGE:-all}"
_STAGE_OK() { [ "$BUILD_STAGE" = "all" ] || [ "$BUILD_STAGE" = "$1" ]; }
# GitHub annotation：存在 check run 里，日志 blob 丢（BlobNotFound）也能从 API 拿
_ANN() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$1" || echo "[stage] $1"; }

# 应用名（build-config.yaml defaults.appname 唯一真源；环境变量 APP_NAME 可覆盖）
APP_NAME="${APP_NAME:-${_CFG_APPNAME:-DeepSeekHarness-NAS}}"
APP_ID="$(echo "$APP_NAME" | tr -d -- '-_')"
APP_NAME_LOWER="$(echo "$APP_NAME" | tr 'A-Z' 'a-z')"

# 套件说明（缺省取源码 README.zh.md 标题段；参数精简后不再收 DESC 参数）
DESC=""
README_ZH="$SRC/README.zh.md"
if [ -f "$README_ZH" ]; then
  DESC="$(sed -n '1,/^## /p' "$README_ZH" \
    | grep -vE '^#|^\[|^$' \
    | sed -E 's/[*_`]//g; s/\[([^]]*)\]\([^)]*\)/\1/g' \
    | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
fi
[ -z "$DESC" ] && DESC="DeepSeek AI 官方开源 agent harness（智能体框架），支持多模型与自定义 OpenAI 兼容端点"

# ----------------------------------------------------------------------------
# pnpm 11 配置桥接（package.json pnpm.* 字段 → pnpm-workspace.yaml）
# ----------------------------------------------------------------------------
BRIDGE_SCRIPT="$D_TOOLS/pnpm-bridge.py"
if [ -f "$BRIDGE_SCRIPT" ] && [ -d "${BUILD_SRC:-$SRC}" ]; then
  _BRIDGE_SRC="${BUILD_SRC:-$SRC}"
  echo "▶ 检查 pnpm 11 配置桥接..."
  ( cd "$_BRIDGE_SRC" && python3 "$BRIDGE_SCRIPT" --dir "." ) 2>/dev/null || true
  echo "✓ pnpm 配置桥接完成"
fi

# ----------------------------------------------------------------------------
# 排除规则（build-excludes.json dist 模式；spk/fpk 打包各自读取自己的条目）
# ----------------------------------------------------------------------------
EXCLUDES_FILE="$SCRIPT_DIR/build-excludes.json"
BLACKLIST_FILE="$SCRIPT_DIR/build-prune-blacklist.json"
WHITELIST_FILE="$SCRIPT_DIR/build-prune-whitelist.json"
_MODE="dist"
if [ -f "$EXCLUDES_FILE" ]; then
  mapfile -t TAR_EXCLUDES < <(python3 -c "
import json
with open('$EXCLUDES_FILE') as f:
    cfg = json.load(f)
items = cfg.get('$_MODE', {}).get('excludes', [])
for x in items:
    if not x.startswith('_comment'):
        print(x)
" 2>/dev/null || true)
  echo "排除规则 : $EXCLUDES_FILE → $_MODE 模式（${#TAR_EXCLUDES[@]} 条规则）"
else
  TAR_EXCLUDES=()
  echo "排除规则 : 未找到 $EXCLUDES_FILE，不排除"
fi

# ----------------------------------------------------------------------------
# 版本（官方完整版本 = FPK 版本；前三位 = SPK 版本）
# ----------------------------------------------------------------------------
PKG_VER="$(python3 -c "import json;print(json.load(open('$SRC/package.json'))['version'])")"
MAIN_VER="$(echo "$PKG_VER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
SPK_VERSION="${MAIN_VER}"
FPK_VERSION="${PKG_VER}"
echo "官方版本 : $PKG_VER  |  SPK 版本: $SPK_VERSION（前三位）  |  FPK 版本: $FPK_VERSION（完整）"

# commit hash（注入 DSH_CLIENT_COMMIT_HASH）
COMMIT_HASH=""
if [ -d "$SRC/.git" ]; then
  COMMIT_HASH="$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null || true)"
fi
[ -z "$COMMIT_HASH" ] && COMMIT_HASH="$(echo -n "${PKG_VER}-${SRC}" | md5sum | cut -c1-7)"
echo "commit     : $COMMIT_HASH"

#===============================================================================
# 一、工作目录 + target 校验/复用
#===============================================================================
WORK="$D_BUILD/spk-build/build-${SPK_VERSION}"
BUILD_SRC="$WORK/source"
TARGET="$WORK/target"
ASSEMBLE="$WORK/assemble"

if [ "$SKIP_BUILD" = "1" ] && [ -d "$TARGET" ] && [ -f "$TARGET/package.json" ]; then
  # 复用旧 target 前校验完整性（按排除/黑名单规则豁免；避免旧副本误打成缺文件包）
  _exempt_top="$(python3 -c "
import json, re
cfg = json.load(open('$EXCLUDES_FILE', encoding='utf-8'))
black = json.load(open('$BLACKLIST_FILE', encoding='utf-8'))
exempt = set()
for x in cfg.get('dist', {}).get('excludes', []):
    if x.startswith('_comment'):
        continue
    m = re.match(r'^--exclude=\./([^/*]+)', x)
    if m:
        exempt.add(m.group(1))
for d in black.get('sourceDirs', []):
    top = d.split('/')[0]
    if top and '/' not in d:
        exempt.add(top)
print('\n'.join(sorted(exempt)))
" 2>/dev/null || true)"
  _src_top="$(ls -1 "$SRC" 2>/dev/null | sort)"
  _tgt_top="$(ls -1 "$TARGET" 2>/dev/null | sort)"
  _missing="$(comm -23 <(echo "$_src_top") <(echo "$_tgt_top") \
    | grep -vxE "$(printf '%s\n' "$_exempt_top" | paste -sd'|' - | sed 's/|/|/g')" \
    | tr '\n' ' ' || true)"
  # native/ 是 node-addon-system-linux-x64 软链真身，启动必需，缺了直接报错
  if [ ! -d "$TARGET/native" ]; then
    echo "[!] target 缺 native/（node-addon-system-linux-x64 软链真身，DSH 启动必需）" >&2
    echo "    请全量构建（去掉 SKIP_BUILD=1）后再打包。" >&2
    exit 1
  fi
  if [ -n "${_missing// /}" ]; then
    echo "[!] 旧 target 缺源码目录（未排除项）: $_missing" >&2
    echo "    target 是旧编译副本，直接复用会打出缺文件的包。请去掉第 2 参数（SKIP_BUILD=0）全量重建。" >&2
    exit 1
  fi
  echo "▶ 复用已有 target 树（skip-build=1，跳过编译；已按排除规则校验完整性）"
  rm -rf "$ASSEMBLE"
  mkdir -p "$ASSEMBLE"
elif [ "$BUILD_STAGE" != "all" ] && [ -f "$BUILD_SRC/package.json" ]; then
  # 分阶段模式：WORK 已由前一阶段准备好，直接复用（不清不删）
  echo "▶ 分阶段模式 (stage=$BUILD_STAGE)：复用已有 WORK $WORK"
  mkdir -p "$WORK" "$TARGET" "$ASSEMBLE"
else
  rm -rf "$WORK"
  mkdir -p "$WORK" "$TARGET" "$ASSEMBLE"
fi

#===============================================================================
# 二、源码副本 + 品牌修改 + 构建（skip-build=1 时跳过）
#===============================================================================
if [ "$SKIP_BUILD" != "1" ]; then
if _STAGE_OK install || _STAGE_OK build; then
# 分阶段 build（stage=build）：BUILD_SRC 已由 install 阶段就绪，跳过复制（否则会覆盖 node_modules）
if [ "$BUILD_STAGE" = "build" ] && [ -f "$BUILD_SRC/package.json" ]; then
  echo "▶ (stage=build) 复用已有构建副本 $BUILD_SRC（跳过复制，保留 node_modules）"
else
  echo "▶ 复制源码到构建副本 $BUILD_SRC"
  cp -a "$SRC" "$BUILD_SRC"
fi

# 品牌: locale 源码（后续 build 会编译进产物）
for loc in en zh; do
  f="$BUILD_SRC/packages/client/locale/src/locales/$loc.ts"
  [ -f "$f" ] && sed -i "s/'DSH Local Build'/'DeepSeekHarness-NAS'/; s/'DSH 本地构建'/'DeepSeekHarness-NAS'/" "$f"
done
echo "✓ locale 品牌已改为 DeepSeekHarness-NAS (en/zh src)"

# 假 .git：构建副本无 .git → 建假 .git 让 build.ts 的 git rev-parse 能取到 commit hash
_FAKE_GIT="$BUILD_SRC/.git"
if [ ! -d "$_FAKE_GIT" ]; then
  mkdir -p "$_FAKE_GIT/refs/heads"
  echo "ref: refs/heads/master" > "$_FAKE_GIT/HEAD"
  echo "${COMMIT_HASH}00000000000000000000000000000000" > "$_FAKE_GIT/refs/heads/master"
fi
_HOME_DIR="$WS/assets/tmp-home"
mkdir -p "$_HOME_DIR"

# ── pnpm 命令垫片（包装：版本锁定 + pnpm10 json → pnpm11 yaml 桥接）─────────
# 为什么必须有这层包装：
#   ① tools/pnpm/bin/ 只有 pnpm.mjs / pnpm.cjs，没有名为 `pnpm` 的可执行入口。
#      上游 scripts/build.ts 用 `sh -c "pnpm run build:lib:*"` 调子脚本（子进程重查
#      PATH），仅把该目录前置到 PATH 仍找不到 `pnpm` → CI 报 `sh: 1: pnpm: not found`
#      （本机靠 /usr/bin/pnpm 兜住，掩盖了该问题）。
#   ② pnpm 11 默认 pmOnFail=download：读到 package.json 的 packageManager 字段就
#      **自动联网下载并切换到那个版本**。官方源码写 `packageManager: pnpm@11.7.0`，
#      于是构建实际跑的不是我们打包/验证过的 pnpm（每次构建多一次 29MB 下载，且
#      版本不受控）。实测对照：目录内 packageManager=pnpm@11.7.0 → 进程版本 11.7.0；
#      改成 11.25.0 或去掉该字段 → 自带版本 11.25.0。`--pm-on-fail=ignore` 可跳过切换
#      （pnpm 源码提示语原文：Set `pmOnFail` to `ignore` to skip the version switch）。
#   ③ pnpm 11 不再读 package.json 的 `pnpm` 字段（onlyBuiltDependencies 等），全改读
#      pnpm-workspace.yaml → 垫片每次调用前自动跑 tools/pnpm-bridge.py 做 json→yaml 转换。
#   三者合一：所有 pnpm 调用（含上游 sh -c 子进程）都锁我们用自带的 pnpm 11 且配置已桥接。
_PNPM_SHIM="$PNPM_BIN_DIR/pnpm"
if [ ! -x "$_PNPM_SHIM" ] || ! grep -q "build-common pnpm shim v2" "$_PNPM_SHIM" 2>/dev/null; then
  cat > "$_PNPM_SHIM" <<SHIMEOF
#!/bin/sh
# build-common pnpm shim v2 —— 由 build/build-common.sh 自动生成，勿手改
# 包装职责：① 版本锁定（--pm-on-fail=ignore，禁用 pnpm 按 packageManager 自动换版本）
#          ② pnpm10 json → pnpm11 yaml 配置桥接（每次调用前幂等执行）
#          ③ 固定用项目自带 pnpm（$PNPM_BIN）+ 打包用 node（$NODE_SRC）
if [ -f "$D_TOOLS/pnpm-bridge.py" ]; then
  python3 "$D_TOOLS/pnpm-bridge.py" --dir "\$PWD" >/dev/null 2>&1 || true
fi
exec "$NODE_SRC" "$PNPM_BIN" --pm-on-fail=ignore "\$@"
SHIMEOF
  chmod 755 "$_PNPM_SHIM"
  echo "✓ 已生成 pnpm 包装垫片: $_PNPM_SHIM（版本锁定 + json→yaml 桥接）"
fi
fi   # 结束准备门控（复制源码+品牌+假git+垫片；stage=prune 时跳过）

# ── install 前应用黑白名单裁剪 devDeps（省 install 磁盘峰值，防 CI 撑爆 runner）──
# 与 prune 阶段共用同一份黑白名单（build-prune-blacklist/whitelist.json，单一权威）：
#   prune-target.sh --before-install 会对 BUILD_SRC 根 package.json 的 devDependencies
#   应用「黑名单 devDeps 候选 → 白名单保护 → 删除」，install 时就不再下载被裁 devDeps
#   （官方 monorepo 依赖树 ~1.78万包，vitest/jsdom/mermaid 等巨大，install 阶段磁盘峰值
#   拉满 → worker 被杀：annotation 实测 No space left on device）。
#   构建必需工具（typescript/tsx/tsdown/lightningcss/execa/smol-toml）已手动追加进
#   白名单 extra（gen-prune-whitelist.sh 自动生成只动 lockfileDeps，不覆盖手动部分），
#   install 时保留，build 不会缺工具。
#   PRUNE_BEFORE_INSTALL=0：跳过 install 前裁剪（本地构建物模式——全量 install 后
#   tsc 类型检查 scripts/** 不再缺包；产物体积由 target 裁剪兜底）。
if _STAGE_OK install && [ "${PRUNE_BEFORE_INSTALL:-1}" = "1" ] && [ -x "$SCRIPT_DIR/prune-target.sh" ]; then
  echo "▶ install 前裁剪 devDeps（复用黑白名单）:$SCRIPT_DIR/prune-target.sh --before-install $BUILD_SRC"
  "$SCRIPT_DIR/prune-target.sh" --before-install "$BUILD_SRC" || echo "  ⚠ install 前裁剪返回非零，继续（不阻断 install）"
elif _STAGE_OK install; then
  echo "▶ install 前裁剪已跳过（PRUNE_BEFORE_INSTALL=${PRUNE_BEFORE_INSTALL:-1}，本地构建物模式：全量 install，tsc 类型检查脚本不再缺包）"
fi

_ANN "stage=$BUILD_STAGE install 开始"
if _STAGE_OK install && [ ! -d "$BUILD_SRC/node_modules" ]; then
  echo "▶ pnpm install (~2-5min) [store=$PNPM_STORE]（项目 pnpm: $PNPM_BIN）"
  # --no-frozen-lockfile：install 前剥离 devDeps 后 package.json 与 lockfile 不一致，
  # CI 环境 pnpm 默认 frozen-lockfile 会报 ERR_PNPM_OUTDATED_LOCKFILE 拒绝安装
  # （实测 2026-09-14：裁剪 23 个 devDeps 后 install 失败）。加此参数重算 lockfile。
  ( cd "$BUILD_SRC" && \
    PATH="$PNPM_BIN_DIR:$PATH" HOME="$_HOME_DIR" PNPM_STORE_DIR="$PNPM_STORE" npm_config_cache="$NPM_CACHE" \
    "$_PNPM_SHIM" install --store-dir="$PNPM_STORE" --force --no-frozen-lockfile 2>&1 | tail -20 )
fi
_ANN "stage=$BUILD_STAGE install 结束 (node_modules=$( [ -d "$BUILD_SRC/node_modules" ] && echo 有 || echo 无))"

if _STAGE_OK build; then
_ANN "stage=$BUILD_STAGE build 开始"
echo "▶ pnpm build (native→lib→web, ~10-20min)"
echo "   注入: DSH_CLIENT_VERSION=$PKG_VER  COMMIT=$COMMIT_HASH  TITLE=DeepSeekHarness-NAS"
_BUILD_LOG="$WORK/pnpm-build.log"    # 完整构建日志（失败时打尾部 80 行，便于 CI 排查）
_BUILD_RC=0
# OOM 防护：tsc 默认 --max-old-space-size=4096
# 旧逻辑只查总内存（RAM+swap），DSH 主实例占 2G+ 时总内存够但可用内存不够 → OOM。
# 新逻辑查 available 内存（free -k Mem 行 available 列），取 60% 作为 tsc 堆上限。
_AVAIL_KB=$(LC_ALL=C free -k 2>/dev/null | awk '/Mem:/{print $7}')
if [ -n "$_AVAIL_KB" ]; then
  _TSX_MEM=$((_AVAIL_KB * 60 / 100 / 1024))   # 可用内存的 60% → MB
  [ "$_TSX_MEM" -lt 1024 ] && _TSX_MEM=1024
  if [ "$_TSX_MEM" -lt 4096 ]; then
    echo "  (可用内存 $((_AVAIL_KB/1024))MB → tsc 堆从 4096MB 降为 ${_TSX_MEM}MB)"
    sed -i "s/--max-old-space-size=[0-9]*/--max-old-space-size=${_TSX_MEM}/" \
      "$BUILD_SRC/package.json" 2>/dev/null || true
  fi
fi
( cd "$BUILD_SRC" && \
  PATH="$PNPM_BIN_DIR:$PATH" HOME="$_HOME_DIR" PNPM_STORE_DIR="$PNPM_STORE" npm_config_cache="$NPM_CACHE" \
  DSH_CLIENT_VERSION="$PKG_VER" \
  DSH_CLIENT_COMMIT_HASH="$COMMIT_HASH" \
  DSH_CLIENT_TITLE="DeepSeekHarness-NAS" \
  "$_PNPM_SHIM" build ) > "$_BUILD_LOG" 2>&1 || _BUILD_RC=$?
# ⚠ 失败时必须把真实报错打出来：原来 `| tail -20` 会把关键错误行截掉，
#   CI 日志只剩最后 20 行，排查困难（2026-09-13 实测）。成功时仍只打尾部。
if [ "${_BUILD_RC:-0}" != "0" ]; then
  echo "✗ pnpm build 失败（退出码 $_BUILD_RC）完整日志: $_BUILD_LOG"
  tail -80 "$_BUILD_LOG"
  exit 1
fi
tail -10 "$_BUILD_LOG"

# 构建产物拷到 target（build.ts 输出在构建副本内，按顶层目录分类拷出）
echo "▶ 组装 target 整树"
for _top in "" apps packages native vendor; do
  if [ -z "$_top" ]; then
    for f in package.json pnpm-workspace.yaml README.md README.zh.md tsconfig.json apps packages native vendor node_modules; do
      [ -e "$BUILD_SRC/$f" ] && cp -a "$BUILD_SRC/$f" "$TARGET/" 2>/dev/null || true
    done
  else
    [ -d "$BUILD_SRC/$_top" ] && cp -a "$BUILD_SRC/$_top" "$TARGET/" 2>/dev/null || true
  fi
done
# 运行需要的顶层文件（.claude 等隐藏目录由 build-excludes.json 排除）
for f in .claude CLAUDE.md AGENTS.md; do
  [ -e "$BUILD_SRC/$f" ] && cp -a "$BUILD_SRC/$f" "$TARGET/" 2>/dev/null || true
done

# 随包 bin/node + dsh + pnpm + var 数据目录
mkdir -p "$TARGET/bin"
cp "$NODE_SRC" "$TARGET/bin/node" 2>/dev/null && chmod +x "$TARGET/bin/node" || echo "⚠ 未找到 node: $NODE_SRC"
sed "s/deepseek-harness-nas/${APP_NAME}/g" "$D_SCRIPTS/dsh" > "$TARGET/bin/dsh"
chmod +x "$TARGET/bin/dsh"
PNPM_SRC=""
for c in "$D_TOOLS/pnpm" "/usr/lib/node_modules/pnpm" "/usr/local/lib/node_modules/pnpm"; do
  [ -f "$c/bin/pnpm.mjs" ] && { PNPM_SRC="$c"; break; }
done
if [ -n "$PNPM_SRC" ]; then
  echo "▶ 随附 pnpm: $PNPM_SRC"
  rm -rf "$TARGET/pnpm"
  mkdir -p "$TARGET/pnpm"
  cp -a "$PNPM_SRC/bin" "$PNPM_SRC/dist" "$TARGET/pnpm/" 2>/dev/null || true
  cp "$PNPM_SRC/package.json" "$TARGET/pnpm/package.json" 2>/dev/null || true
  cp "$D_TOOLS/pnpm-bridge.py" "$TARGET/pnpm/pnpm-bridge.py" 2>/dev/null || true
  echo "  ✓ pnpm 随附完成 ($(du -sh "$TARGET/pnpm" 2>/dev/null | cut -f1))"
else
  echo "  ⚠ 未找到 pnpm 源（$D_TOOLS/pnpm 或 /usr/lib/node_modules/pnpm）"
fi
if [ -f "$D_SCRIPTS/pnpm" ]; then
  sed "s/deepseek-harness-nas/${APP_NAME}/g" "$D_SCRIPTS/pnpm" > "$TARGET/bin/pnpm"
  chmod +x "$TARGET/bin/pnpm"
  echo "  ✓ bin/pnpm 包装器生成"
else
  echo "  ⚠ 未找到 pnpm 包装器模板（$D_SCRIPTS/pnpm）"
fi
mkdir -p "$TARGET/var/logs" "$TARGET/var/data" "$TARGET/.dsh-home/.dsh"

# 门户图标资源统一放 target/ui/images（DSM 与 fnOS 门户都读 application 位于 ui/）
mkdir -p "$TARGET/ui/images"
cp "$D_ASSETS/ui/images/"*.png "$TARGET/ui/images/" 2>/dev/null || true

echo "▶ target 待裁剪: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
_ANN "stage=$BUILD_STAGE build 结束 (target=$(du -sh "$TARGET" 2>/dev/null | cut -f1))"
fi   # 结束 build 门控（stage=install/prune 时跳过 build+组装）

#===============================================================================
# 三、预构建包裁剪（黑白名单配置驱动；规则权威 = build-prune-blacklist/whitelist.json）
#   独立脚本 prune-target.sh 承载（本文件同目录）；此处调用，行为与原内联一致。
#   执行顺序：黑名单收集候选 → 白名单过滤（命中 = 保留，白大于黑）→ rm -rf
#   ⚠ native/ 不在黑名单 sourceDirs：node-addon-system-linux-x64 软链真身，删了启动必挂
#===============================================================================
if _STAGE_OK prune; then
_ANN "stage=$BUILD_STAGE prune 开始"
"$SCRIPT_DIR/prune-target.sh" "$TARGET" "$BLACKLIST_FILE" "$WHITELIST_FILE"
_ANN "stage=$BUILD_STAGE prune 结束"
fi

fi   # 结束「二、源码副本 + 构建 + 三、裁剪」（skip-build=1 复用 target 时整体跳过）

#===============================================================================
# 四、写 build-meta.env（spk/fpk 打包脚本 source 的元数据，单一真源）
#===============================================================================
cat > "$WORK/build-meta.env" <<EOF
# 由 build-common.sh 生成（$(date '+%F %T')）；build-spk.sh / build-fpk.sh source 本文件
APP_NAME='${APP_NAME}'
APP_ID='${APP_ID}'
APP_NAME_LOWER='${APP_NAME_LOWER}'
PKG_VER='${PKG_VER}'
SPK_VERSION='${SPK_VERSION}'
FPK_VERSION='${FPK_VERSION}'
DESC='${DESC}'
COMMIT_HASH='${COMMIT_HASH}'
WORK='${WORK}'
TARGET='${TARGET}'
EOF

echo ""
echo "════════════════════════════════════════════════"
echo "✅ target 预编译完成"
echo "  target   : $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
echo "  元数据   : $WORK/build-meta.env"
echo "  APP_NAME : $APP_NAME | dsh $PKG_VER | SPK $SPK_VERSION | FPK $FPK_VERSION"
echo "────────────────────────────────────────────────"
echo "后续打包（二选一或都做）:"
echo "  ./build-spk.sh    构建 SPK（群晖）"
echo "  ./build-fpk.sh    构建 FPK（飞牛）"
echo "════════════════════════════════════════════════"