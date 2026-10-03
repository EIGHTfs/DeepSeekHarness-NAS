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
#                  或 master-build/master-build）
#   2. SKIP_BUILD  1=复用已有完整 target（不重新构建；缺省=1 跳过已存在，=0 强制全量构建）
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
#   target 整树       build/master-build/build-<SPK_VERSION>/target（编译+裁剪后装包内容）
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

# ── NODE_SRC 自探测（2026-10-02）────────────────────────────────────────────
# 打包进应用的 node 二进制。0.2.0 起官方 native/system 需编译 node-api 附件
# （flock.c），依赖 node 发行版自带的 include/node 头文件——套件裁剪 node 没有，
# 故不能只看"有没有 node"，必须校验 headers 存在。探测顺序：
#   ① 显式传入 $NODE_SRC（环境变量，最高优先，CI 用 setup-node 路径走这里）
#   ② 项目自备 tools/node-dist/node-v*/bin/node（含 include/node，本地构建用）
#   ③ PATH 里的 node 且带 include/node 头文件
#   ④ 兜底 /usr/bin/node（历史默认，保持向后兼容）
node_has_headers() {  # $1=node 可执行文件路径 → 校验同级/上级 include/node/node_api.h
  local _n="$1" _d
  [ -x "$_n" ] || return 1
  _d="$(dirname "$_n")"
  [ -f "$_d/../include/node/node_api.h" ] || [ -f "$_d/include/node/node_api.h" ]
}
resolve_node_src() {
  local _c=""
  # ① 首选 /usr/bin/node —— 但**必须可执行**才算数。
  #    旧写法最后直接 echo /usr/bin/node，不校验存在性：本机（193）该路径不存在，
  #    于是垫片被写死成 exec "/usr/bin/node" → 每次 pnpm install 都
  #    "/usr/bin/node: No such file or directory"（实测 2026-10-03）。
  #    用户口径：优先 /usr/bin/node，不可执行则自探测。
  if [ -x /usr/bin/node ]; then echo "/usr/bin/node"; return 0; fi
  # ② 自探测（先要带 headers 的：native 编译需要）
  _c="$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1)"
  if node_has_headers "$_c"; then echo "$_c"; return 0; fi
  _c="$(command -v node 2>/dev/null || true)"
  if node_has_headers "$_c"; then echo "$_c"; return 0; fi
  # ③ 退一步：任何**可执行**的 node（不带 headers 也比写死不存在强）
  for _c in /usr/local/bin/node \
            "$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1)" \
            "$(command -v node 2>/dev/null || true)" \
            /volume1/@appstore/DeepSeekHarness-NAS/bin/node; do
    [ -n "$_c" ] && [ -x "$_c" ] && { echo "$_c"; return 0; }
  done
  echo "/usr/bin/node"
}
if [ -z "${NODE_SRC:-}" ]; then
  NODE_SRC="$(resolve_node_src)"
  echo "▶ NODE_SRC 自探测: $NODE_SRC"
fi
# 自探测到的 node 目录注入 PATH：pnpm 运行 package scripts（tsx/tsdown/web build）
# 需要 PATH 里有 node 可执行文件（shim 里虽用绝对路径 exec，但子进程仍靠 PATH）
if [ -x "$NODE_SRC" ]; then
  case ":$PATH:" in
    *":$(dirname "$NODE_SRC"):"*) ;;
    *) PATH="$(dirname "$NODE_SRC"):$PATH"; export PATH ;;
  esac
fi

# ── pnpm 引擎自举（2026-09-16：tools/pnpm/dist 不入库，见 .gitignore）──
#   bin/pnpm.mjs 只是入口（await import('../dist/pnpm.mjs') 引擎在 dist/）；
#   dist 为 pnpm 官方安装产物（457 文件大 bundle），不入 git。CI / 新 clone 后
#   bin 在但 dist 缺失 → 此处自动用 npm 下载 pnpm 官方包解压补全，保证构建可用。
ensure_pnpm_engine() {
  if [ -f "$PNPM_BIN" ] && [ -f "$WS/tools/pnpm/dist/pnpm.mjs" ]; then
    return 0  # bin + dist 齐全，直接可用
  fi
  echo "▶ pnpm 引擎缺失（tools/pnpm/dist 不入库），自动安装 pnpm…"
  mkdir -p "$WS/tools/pnpm"
  local _ver _tmp
  _ver="$(cat "$WS/tools/pnpm/package.json" 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('version','11.25.0'))" 2>/dev/null \
    || echo '11.25.0')"
  _tmp="$(mktemp -d)"
  if command -v npm >/dev/null 2>&1; then
    ( cd "$_tmp" && npm pack "pnpm@$_ver" --silent 2>/dev/null ) \
      && tar -xzf "$_tmp"/pnpm-*.tgz -C "$WS/tools/pnpm" --strip-components=1 2>/dev/null
  fi
  rm -rf "$_tmp"
  if [ -f "$WS/tools/pnpm/dist/pnpm.mjs" ]; then
    echo "  ✓ pnpm 引擎就绪 (tools/pnpm/dist/pnpm.mjs, v$_ver)"
  else
    echo "  ✗ pnpm 引擎安装失败：npm 不可用或下载失败，请 npm install -g pnpm@$_ver 后重试" >&2
    return 1
  fi
}
ensure_pnpm_engine

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
# ── 本脚本引用的脚本/目录路径（常量；改路径只改这里，引用点一律用常量） ──
BUILD_ROOT="$SCRIPT_DIR"
WORK_ROOT="${D_WORK_ROOT:-$BUILD_ROOT/master-build}"         # 构建中间产物根（原 spk-build → master-build）
PRUNE_SCRIPT="$BUILD_ROOT/prune-target.sh"                   # 裁剪脚本（通用，本目录）
GEN_WHITELIST_SCRIPT="$BUILD_ROOT/gen-prune-whitelist.sh"    # 白名单生成（通用，本目录）
SPK_BUILD_SCRIPT="$BUILD_ROOT/SPK/build-spk.sh"              # SPK 打包（build/SPK/）
FPK_BUILD_SCRIPT="$BUILD_ROOT/FPK/build-fpk.sh"              # FPK 打包（build/FPK/）
NPM_FPK_SCRIPT="$BUILD_ROOT/FPK/build-npm-fpk-app.sh"        # FPK npm 链路（build/FPK/）
# 参数：--dry-run 可出现在任意位置（亦可用环境变量 DRY_RUN=1）；其余按位置 = SRC SKIP_BUILD
DRY_RUN="${DRY_RUN:-0}"
_POS=()
for _a in "$@"; do
  case "$_a" in
    --dry-run|--dryrun) DRY_RUN=1 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) _POS+=("$_a") ;;
  esac
done
SRC="${_POS[0]:-}"
if [ -z "$SRC" ]; then
  # 通配扫描 src/deepseek-ai/*（不硬编码版本目录名），其次 master-build；
  # 多个候选时按 semver 取**最新**——2026-10-02 修复：原实现取 glob 字典序第一个，
  # 本地同时存在 dsh-v0.1.5-rc.2（旧）与 dsh-v0.2.0-rc.2（新）时会误选旧版构建。
  _cands=()
  for cand in "$D_SRC"/deepseek-ai/* "$WORK_ROOT"/master-build/*; do
    if [ -f "$cand/package.json" ] && [ -d "$cand/apps/cli" ]; then
      _cands+=("$cand")
    fi
  done
  if [ "${#_cands[@]}" -gt 0 ]; then
    SRC="$(printf '%s\n' "${_cands[@]}" | python3 -c '
import sys, re
def vkey(p):
    m = re.search(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)([^/]*)", p)
    if not m:
        return (0, 0, 0, 0, "")
    a, b, c, rest = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
    stable = 1 if rest == "" else 0   # 无预发布后缀 = 正式版，优先
    return (a, b, c, stable, rest)
cands = [l.strip() for l in sys.stdin if l.strip()]
print(sorted(cands, key=vkey)[-1])
')"
    echo "▶ 源码自探测: $SRC（候选取最新 semver，共 ${#_cands[@]} 个）"
  fi
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/package.json" ]; then
  echo "✗ 未找到源码目录。用法: $0 [SRC] [SKIP_BUILD] [--dry-run]" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"
SKIP_BUILD="${SKIP_BUILD:-${_POS[1]:-1}}"   # 默认跳过已存在的 target（=0 强制全量重建）；支持环境变量或第 2 位置参数（2026-10-02：原先只读位置参数，环境变量写法会被静默忽略）
# 分阶段构建门控：all | install | build | prune（CI 把长步骤拆成 3 个独立 step，
# 靠 step 结论定位死点；分阶段时复用已有 WORK，不清不删）
BUILD_STAGE="${BUILD_STAGE:-all}"
_STAGE_OK() { [ "$BUILD_STAGE" = "all" ] || [ "$BUILD_STAGE" = "$1" ]; }

# ── 编译 dry-run（2026-10-02）：所有阶段均可预演，不执行任何编译/裁剪/写盘 ──
#   ./build-common.sh [SRC] [SKIP_BUILD] --dry-run     # 或 DRY_RUN=1
#   仅报告：阶段计划、源码/版本/node/编译器自探测结果、白名单与排除规则统计、
#   现有 target 体积、各阶段将执行的具体动作（逐条 [dry-run] 列出）。
_dry() { [ "$DRY_RUN" = "1" ]; }
# 预演提示（dry-run 时打印一行；非 dry-run 静默）
dry_note() { if _dry; then echo "  [dry-run] $1"; fi; return 0; }
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
# ── 构建目录：**单一复用**（用户口径 2026-10-03：「旧产物可以复用，别分 build 版本」）──
#   旧写法 build-<SPK_VERSION>：每换一个版本就新建整树 → 实测堆出约 10G 重复
#   （build-0.1.5 / build-0.2.0 / build-0.2.1 / npm-app-*），且每次都要全量 pnpm install
#   （install 阶段光完整性校验就 539s）。
#   现在：跨版本**复用同一目录**，source/node_modules 由 pnpm 增量 reconcile（秒~分钟级）；
#   配合既有的 SKIP_BUILD=1（复用 target）与 BUILD_STAGE=build|prune（跳过 install）实现"改哪跑哪"。
#   需要全新构建时显式 FRESH_BUILD=1：旧目录**带时间戳归档**（不直接删，可回溯）。
WORK_NAME="${WORK_NAME:-build}"
WORK="$WORK_ROOT/$WORK_NAME"
if [ "${FRESH_BUILD:-0}" = "1" ] && [ -d "$WORK" ]; then
  _work_bak="$WORK_ROOT/${WORK_NAME}.bak-$(date +%Y%m%d-%H%M%S)"
  echo "▶ FRESH_BUILD=1：归档旧构建目录 → $_work_bak"
  mv "$WORK" "$_work_bak"
fi
BUILD_SRC="$WORK/source"
TARGET="$WORK/target"
ASSEMBLE="$WORK/assemble"

# ── 编译 dry-run 预演（所有阶段；不执行任何动作，逐条列出计划）──────────────
if _dry; then
  echo "════════════════ DRY-RUN 编译预演（不执行、不改动）════════════════"
  echo "阶段      : $BUILD_STAGE   （all=全流程；可分阶段 install|build|prune）"
  echo "源码      : $SRC"
  echo "构建副本  : $BUILD_SRC"
  echo "target    : $TARGET"
  echo "版本      : dsh $PKG_VER | SPK $SPK_VERSION | FPK $FPK_VERSION | commit $COMMIT_HASH"
  echo "应用名    : $APP_NAME"
  echo "NODE_SRC  : $NODE_SRC"
  _cc_bin="$(command -v cc 2>/dev/null || true)"
  if [ -n "$_cc_bin" ]; then
    echo "C 编译器  : $_cc_bin（native/system 走真实编译）"
  else
    echo "C 编译器  : 无 → 将启用 cc 替身 + 官方预编译 native 产物"
  fi
  echo "排除规则  : ${#TAR_EXCLUDES[@]} 条（$EXCLUDES_FILE）"
  echo -n "白名单    : "
  if [ -f "$WHITELIST_FILE" ]; then
    python3 - "$WHITELIST_FILE" <<'PYD'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    def n(k):   # 容错：字段缺失或非数组（如说明用 bool）时计 0
        v = d.get(k)
        return len(v) if isinstance(v, list) else 0
    print(f"extra={n('extra')} lockfileDeps={n('lockfileDeps')} "
          f"workspaceRuntimeDeps={n('workspaceRuntimeDeps')}  ({sys.argv[1]})")
except Exception as e:
    print(f"⚠ 解析失败: {e}")
PYD
  else
    echo "⚠ 未找到 $WHITELIST_FILE"
  fi
  if [ -d "$TARGET" ]; then
    echo "现有 target: $(du -sh "$TARGET" 2>/dev/null | cut -f1)  （未裁剪的大体积需单独跑 BUILD_STAGE=prune）"
  else
    echo "现有 target: 不存在（全新构建）"
  fi
  echo
  if _STAGE_OK install; then
    echo "【install 阶段】将执行："
    if [ -f "$BUILD_SRC/package.json" ] && [ "$BUILD_STAGE" != "all" ]; then
      echo "  1. 复用已有构建副本（跳过源码复制，保留 node_modules）"
    else
      echo "  1. 复制源码 → $BUILD_SRC"
      echo "  2. 品牌名替换（locale en/zh：DeepSeek Harness → $APP_NAME）"
    fi
    echo "  3. 生成 pnpm 包装垫片 $PNPM_BIN_DIR/pnpm（版本锁定 --pm-on-fail=ignore + json→yaml 桥接）"
    if [ "${PRUNE_BEFORE_INSTALL:-1}" = "1" ]; then
      echo "  4. 裁剪 devDeps：prune-target.sh --before-install $BUILD_SRC（白名单外 devDep 删除）"
    else
      echo "  4. 跳过 install 前裁剪（PRUNE_BEFORE_INSTALL=0）"
    fi
    echo "  5. pnpm install --store-dir=$PNPM_STORE --force --no-frozen-lockfile"
    if [ "${PRUNE_BEFORE_BUILD:-1}" = "1" ]; then
      echo "  6. build 前裁剪：prune-target.sh --node-modules $BUILD_SRC（纯白名单 + extra 构建工具）"
      echo "     → build 在精简依赖树上跑（避免全量 8G 峰值）"
    else
      echo "  6. 跳过 build 前裁剪（PRUNE_BEFORE_BUILD=0）"
    fi
  fi
  if _STAGE_OK build; then
    echo "【build 阶段】将执行："
    if [ -n "$_cc_bin" ]; then
      echo "  1. native/system：cc 编译 flock.c（--host-addon-only）"
    else
      echo "  1. native/system：cc 替身复用官方预编译产物（免编译）"
    fi
    echo "  2. build:lib:host（tsc -b tsconfig.host.json + tsdown host；堆上限 ${DSH_TSC_MEM:-可用内存的75%}）"
    echo "  3. build:lib:client（tsc -b tsconfig.client.json + tsdown client）"
    echo "  4. build:web（前端构建）"
    echo "  5. 组装 target 整树 → $TARGET（随附 pnpm）"
  fi
  if _STAGE_OK prune; then
    echo "【prune 阶段】将执行："
    echo "  1. prune-target.sh $TARGET $WHITELIST_FILE"
    echo "     （纯白名单裁剪：删 .pnpm 中非白名单包 + 非目标平台二进制 → target 体积骤降）"
  fi
  if _STAGE_OK install; then
    echo "【meta】写 $WORK/build-meta.env（APP_NAME/PKG_VER/SPK_VERSION/FPK_VERSION/COMMIT）"
  fi
  echo "════════════════ 预演结束（未执行任何动作、未改动任何文件）════════════════"
  exit 0
fi

if [ "$SKIP_BUILD" = "1" ] && [ -f "$WORK/.build-done" ] && [ -d "$TARGET" ] && [ -f "$TARGET/package.json" ]; then
  # 断点续传：构建已完成（有 .build-done 标记）→ 跳过，直接复用 target
  echo "▶ 复用已有 target（$WORK/.build-done 存在，跳过编译）"
  rm -rf "$ASSEMBLE"
  mkdir -p "$ASSEMBLE"
  _BUILD_SKIPPED=1
elif [ "$BUILD_STAGE" != "all" ] && [ -f "$BUILD_SRC/package.json" ]; then
  # 分阶段模式：WORK 已由前一阶段准备好，直接复用（不清不删）
  echo "▶ 分阶段模式 (stage=$BUILD_STAGE)：复用已有 WORK $WORK"
  mkdir -p "$WORK" "$TARGET" "$ASSEMBLE"
else
  rm -rf "$WORK"
  mkdir -p "$WORK" "$TARGET" "$ASSEMBLE"
fi

#===============================================================================
# 二、源码副本 + 品牌修改 + 构建（已跳过时跳过）
#===============================================================================
if [ "${_BUILD_SKIPPED:-0}" != "1" ]; then
if _STAGE_OK install || _STAGE_OK build; then
# 分阶段 build（stage=build）：BUILD_SRC 已由 install 阶段就绪，跳过复制（否则会覆盖 node_modules）
if [ "$BUILD_STAGE" = "build" ] && [ -f "$BUILD_SRC/package.json" ]; then
  echo "▶ (stage=build) 复用已有构建副本 $BUILD_SRC（跳过复制，保留 node_modules）"
else
  echo "▶ 复制源码到构建副本 $BUILD_SRC"
  # ⚠ cp -a 语义坑（2026-10-02 实测修复）：`cp -a SRC DST` 在 **DST 已存在** 时，会把
  #   SRC 复制成 DST/<SRC 的 basename>（嵌套），而不是覆盖 DST 内容。分阶段
  #   stage=install 复用已有 WORK 时必踩：会生成 source/dsh-v0.2.0-rc.2/ 并把源码
  #   复制进子目录（还可能在 .git 大文件上失败中断）→ 后续 install/build 全乱。
  #   故先清目标，保证结果恒为「DST = SRC 的内容」。
  #
  # ⚠ 深硬链目录坑（2026-10-03 实测修复）：pnpm 的 node_modules/.pnpm 是**深硬链目录**，
  #   在 ZFS/CIFS/NFS 上 `cp -a` 递归复制会报「Directory not empty」而中断 —— 实测
  #   .../@playwright+mcp@0.0.80/...: Directory not empty → 构建中止、日志停在"复制源码"，
  #   且留下半成品 BUILD_SRC 让下次重跑继续踩。
  #   改用 **tar 管道 + --hard-dereference**（硬链展开为真实文件、软链保留），与
  #   build/FPK/build-fpk.sh 的 app.tgz 段同一套实现（那里也是为规避深目录复制失败）。
  rm -rf "$BUILD_SRC"
  mkdir -p "$BUILD_SRC"
  ( cd "$SRC" && tar -cf - --hard-dereference . ) | ( cd "$BUILD_SRC" && tar -xf - )
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
if [ ! -x "$_PNPM_SHIM" ] || ! grep -q "build-common pnpm shim v3" "$_PNPM_SHIM" 2>/dev/null; then
  cat > "$_PNPM_SHIM" <<SHIMEOF
#!/bin/sh
# build-common pnpm shim v3 —— 由 build/build-common.sh 自动生成，勿手改
# 包装职责：① 版本锁定（--pm-on-fail=ignore，禁用 pnpm 按 packageManager 自动换版本）
#          ② pnpm10 json → pnpm11 yaml 配置桥接（每次调用前幂等执行）
#          ③ 固定用项目自带 pnpm（$PNPM_BIN）+ 打包用 node（$NODE_SRC）
if [ -f "$D_TOOLS/pnpm-bridge.py" ]; then
  python3 "$D_TOOLS/pnpm-bridge.py" --dir "\$PWD" >/dev/null 2>&1 || true
fi
# node 解析：生成期写死的优先，但**运行期再自愈一次** —— 生成期的 /usr/bin/node 可能
# 在这台机上不存在（实测 193），写死路径会让所有 pnpm 调用直接失败。
# ⚠ 本段处在**未加引号的 heredoc** 内：应在垫片里保持变量的写法必须转义 \$，
#   否则会被生成期的 set -u 判为 unbound variable（实测踩坑）。
_PNPM_NODE="$NODE_SRC"
if [ ! -x "\$_PNPM_NODE" ]; then
  for _c in /usr/bin/node /usr/local/bin/node; do
    [ -x "\$_c" ] && { _PNPM_NODE="\$_c"; break; }
  done
fi
[ -x "\$_PNPM_NODE" ] || _PNPM_NODE="\$(command -v node 2>/dev/null || true)"
if [ -z "\$_PNPM_NODE" ] || [ ! -x "\$_PNPM_NODE" ]; then
  echo "[pnpm-shim] 找不到可执行的 node（试过 $NODE_SRC、/usr/bin/node、/usr/local/bin/node、PATH）" >&2
  exit 127
fi
exec "\$_PNPM_NODE" "$PNPM_BIN" --pm-on-fail=ignore "\$@"
SHIMEOF
  chmod 755 "$_PNPM_SHIM"
  echo "✓ 已生成 pnpm 包装垫片: $_PNPM_SHIM（版本锁定 + json→yaml 桥接）"
fi
fi   # 结束准备门控（复制源码+品牌+假git+垫片；stage=prune 时跳过）

# ── install 前纯白名单裁剪 devDeps（省 install 磁盘峰值，防 CI 撑爆 runner）──
# prune-target.sh --before-install 对 BUILD_SRC 根 package.json 的 devDependencies
# 应用纯白名单：不在白名单（extra + lockfileDeps + workspaceRuntimeDeps）的 devDep
# 一律删除，install 时就不再下载（vitest/jsdom/mermaid 等巨大）。
# 构建必需工具（typescript/tsx/tsdown/lightningcss/execa/smol-toml）已手动追加进
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
  # ── 网络容错（2026-10-03）：官方 0.2.1 的 @openai/codex 多平台 optional 包下载
  #    error(23) 超时（默认 fetch-timeout=60s/retries=2）→ 整个 install 失败。
  #    ① npm_config_fetch_timeout=600s + fetch_retries=5 + network_concurrency=8
  #       （降低并发稳单包下载，pnpm 兼容 npm_config_* 环境变量）
  #    ② install 失败自动重试 3 次（间隔 30s，瞬时网络抖动标准解法）
  #    ③ 仍失败切 npmmirror 镜像兜底一次（registry.npmjs.org 海外偶发不稳）
  _PNPM_LOG="$WS/assets/pnpm-install.log"
  _pnpm_install() {  # $1 额外参数（如 --registry）；退出码=pnpm 真实退出码
    ( cd "$BUILD_SRC" && \
      PATH="$PNPM_BIN_DIR:$PATH" HOME="$_HOME_DIR" PNPM_STORE_DIR="$PNPM_STORE" \
      npm_config_cache="$NPM_CACHE" \
      npm_config_fetch_timeout=600000 npm_config_fetch_retries=5 npm_config_network_concurrency=8 \
      "$_PNPM_SHIM" install --store-dir="$PNPM_STORE" --force --no-frozen-lockfile "${1:-}" \
      > "$_PNPM_LOG" 2>&1 )
  }
  _inst_ok=1
  for _attempt in 1 2 3; do
    echo "  → pnpm install 尝试 $_attempt/3（fetch-timeout=600s, retries=5）"
    if _pnpm_install; then _inst_ok=0; break; fi
    tail -15 "$_PNPM_LOG" 2>/dev/null || true
    echo "  ⚠ pnpm install 第 $_attempt 次失败，30s 后重试" >&2
    [ "$_attempt" -lt 3 ] && sleep 30
  done
  if [ "$_inst_ok" = "1" ]; then
    echo "  ⚠ 默认源 3 次失败，切 npmmirror 镜像最后尝试" >&2
    _pnpm_install "--registry=https://registry.npmmirror.com" && _inst_ok=0 || true
  fi
  if [ "$_inst_ok" = "1" ]; then
    echo "✗ pnpm install 4 次尝试均失败，最近日志见 $_PNPM_LOG" >&2
    exit 1
  fi
  tail -5 "$_PNPM_LOG" >&2
fi
_ANN "stage=$BUILD_STAGE install 结束 (node_modules=$( [ -d "$BUILD_SRC/node_modules" ] && echo 有 || echo 无))"

# ── build 前裁剪（2026-10-02，默认开）：install 完成立即按白名单裁 BUILD_SRC/node_modules/.pnpm，
#   使 pnpm build 在**精简依赖树**上运行，避免「全量 install 8G → 编译 → 末尾才裁」的磁盘/内存峰值。
#   白名单含 extra（构建工具：typescript/tsx/tsdown/lightningcss 等），否则 build 会缺包。
#   PRUNE_BEFORE_BUILD=0 关闭（回退为仅末尾 target 裁剪）。
if _STAGE_OK build && [ "${PRUNE_BEFORE_BUILD:-1}" = "1" ] && [ -x "$SCRIPT_DIR/prune-target.sh" ]; then
  if _dry; then
    dry_note "build 前裁剪：prune-target.sh --node-modules $BUILD_SRC（纯白名单 + extra）"
  else
    echo "▶ build 前裁剪 node_modules（纯白名单 + extra 构建工具）"
    "$SCRIPT_DIR/prune-target.sh" --node-modules "$BUILD_SRC" "$WHITELIST_FILE" \
      || echo "  ⚠ build 前裁剪返回非零，继续（不阻断 build）"
  fi
elif _STAGE_OK build; then
  echo "▶ build 前裁剪已跳过（PRUNE_BEFORE_BUILD=${PRUNE_BEFORE_BUILD:-1}）"
fi

if _STAGE_OK build; then
_ANN "stage=$BUILD_STAGE build 开始"

# ── native/system 编译自探测（2026-10-02）──────────────────────────────────
# 0.2.0 起官方 build:native-system 用 cc 编译 flock.c（Node-API 附件）+ musl-gcc 编
# landlock-run；host-addon-only 模式只需 cc 出 glibc/system.node。部分环境（DSM 套件机、
# 精简容器）无 C 编译器 → 这里自探测：无 cc 时用「cc 替身 + 官方预编译产物」复用，
# 保持官方 build 链完全不变（writeClientBuildRecord 等后续步骤照跑）。
# 复用依据：官方 native 产物确定性（实测三个不同来源 system.node md5 全为
# 36a017660f00886cb9b42b427cefc347），故与 CI 编译产物一致。
_NATIVE_SHIM_DIR=""
if ! command -v cc >/dev/null 2>&1; then
  _nat_host="linux-x64"
  case "$(uname -m)" in aarch64|arm64) _nat_host="linux-arm64" ;; esac
  _nat_pre="$BUILD_SRC/native/system/packages/$_nat_host/bin/glibc/system.node"
  if [ ! -f "$_nat_pre" ]; then
    # ① 已装套件里的现成产物（/var/packages/<pkg>/target/native/…）
    _nat_pre="$(find /var/packages -maxdepth 8 -path "*native/system/packages/$_nat_host/bin/glibc/system.node" 2>/dev/null | head -1)"
  fi
  if [ -z "$_nat_pre" ] || [ ! -f "$_nat_pre" ]; then
    # ② 工作区构建缓存里的官方 npm 包产物（@deepseek-ai/node-addon-system-<host>）
    _nat_pre="$(find "$WS/build/master-build" -maxdepth 9 -path "*node-addon-system-$_nat_host/bin/glibc/system.node" 2>/dev/null | head -1)"
  fi
  if [ -n "$_nat_pre" ] && [ -f "$_nat_pre" ]; then
    _NATIVE_SHIM_DIR="$WORK/native-shim"
    mkdir -p "$_NATIVE_SHIM_DIR"
    cat > "$_NATIVE_SHIM_DIR/cc" <<SHIM
#!/bin/sh
# cc 替身（build-common.sh 自动生成）：无 C 编译器环境复用官方预编译 native 产物。
# 官方 build.ts 以 \`cc ... -o <output> <source>\` 调用；本替身忽略编译参数，
# 直接把预编译产物落到 -o 指定路径，使官方构建链无需改动即可完成。
_out=""; _prev=""
for _a in "\$@"; do
  if [ "\$_prev" = "-o" ]; then _out="\$_a"; break; fi
  _prev="\$_a"
done
if [ -z "\$_out" ]; then echo "cc-shim: 未解析到 -o 输出路径" >&2; exit 1; fi
mkdir -p "\$(dirname "\$_out")"
cp "$_nat_pre" "\$_out" && chmod 755 "\$_out" || exit 1
echo "cc-shim: 复用官方预编译产物 → \$_out（源 $_nat_pre）" >&2
exit 0
SHIM
    chmod 755 "$_NATIVE_SHIM_DIR/cc"
    cp "$_NATIVE_SHIM_DIR/cc" "$_NATIVE_SHIM_DIR/musl-gcc"
    echo "▶ 无 C 编译器 → 自探测到官方预编译产物，启用 cc 替身复用"
    echo "   产物: $_nat_pre"
  else
    echo "⚠ 无 C 编译器且未找到官方预编译产（native/system/packages/$_nat_host/bin/glibc/system.node）" >&2
    echo "   native 编译将失败；请提供编译器或预编译产物。" >&2
  fi
fi

echo "▶ pnpm build (native→lib→web, ~10-20min)"
echo "   注入: DSH_CLIENT_VERSION=$PKG_VER  COMMIT=$COMMIT_HASH  TITLE=DeepSeekHarness-NAS"
_BUILD_LOG="$WORK/pnpm-build.log"    # 完整构建日志（失败时打尾部 80 行，便于 CI 排查）
_BUILD_RC=0
# OOM 防护：tsc 默认 --max-old-space-size=4096
# 旧逻辑只查总内存（RAM+swap），DSH 主实例占 2G+ 时总内存够但可用内存不够 → OOM。
# 新逻辑查 available 内存（free -k Mem 行 available 列），取 60% 作为 tsc 堆上限。
_AVAIL_KB=$(LC_ALL=C free -k 2>/dev/null | awk '/Mem:/{print $7}')
if [ -n "$_AVAIL_KB" ]; then
  # 2026-10-02：比例 60% → 75%，并支持 DSH_TSC_MEM 显式覆盖。
  # 原因：0.2.0 源码 tsc -b tsconfig.host.json 需要 >2.3GB 堆；60% 在 3.8GB 可用内存
  # 的机器上只给 2316MB → FATAL heap out of memory（本机实测 197s 后 OOM 退出 134）。
  # 堆上限是"上限"非预分配，设大无害（物理不够时走 swap）。
  _TSX_MEM="${DSH_TSC_MEM:-$((_AVAIL_KB * 75 / 100 / 1024))}"
  [ "$_TSX_MEM" -lt 1024 ] && _TSX_MEM=1024
  echo "  (tsc 堆上限 ${_TSX_MEM}MB（物理可用 $((_AVAIL_KB/1024))MB）；可用 DSH_TSC_MEM=<MB> 覆盖)"
  # 无条件写入：BUILD_STAGE=build 复用构建副本时，package.json 会残留上一轮的堆值
  sed -i "s/--max-old-space-size=[0-9]*/--max-old-space-size=${_TSX_MEM}/" \
    "$BUILD_SRC/package.json" 2>/dev/null || true
fi
( cd "$BUILD_SRC" && \
  PATH="${_NATIVE_SHIM_DIR:+$_NATIVE_SHIM_DIR:}$PNPM_BIN_DIR:$PATH" HOME="$_HOME_DIR" PNPM_STORE_DIR="$PNPM_STORE" npm_config_cache="$NPM_CACHE" \
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
# 三、预构建包裁剪（纯白名单；规则权威 = build-prune-whitelist.json）
#   独立脚本 prune-target.sh 承载（本文件同目录）。
#   .pnpm 里不在 lockfileDeps + workspaceRuntimeDeps 的一律删除。
#   ⚠ native/ 保留：node-addon-system-linux-x64 软链真身，删了启动必挂
#===============================================================================
if _STAGE_OK prune; then
_ANN "stage=$BUILD_STAGE prune 开始"
"$SCRIPT_DIR/prune-target.sh" "$TARGET" "$WHITELIST_FILE"
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
touch "$WORK/.build-done"   # 断点续传标记：下次 SKIP_BUILD=1 时跳过
echo "  target   : $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
echo "  元数据   : $WORK/build-meta.env"
echo "  APP_NAME : $APP_NAME | dsh $PKG_VER | SPK $SPK_VERSION | FPK $FPK_VERSION"
echo "────────────────────────────────────────────────"
echo "后续打包（二选一或都做）:"
echo "  ./build-spk.sh    构建 SPK（群晖）"
echo "  ./build-fpk.sh    构建 FPK（飞牛）"
echo "════════════════════════════════════════════════"