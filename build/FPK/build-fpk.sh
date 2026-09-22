#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — FPK 打包脚本（飞牛 fnOS x86）
#===============================================================================
# 【三脚本分工】2026-09-13 从原 build.sh（spk+fpk 混合 1216 行）拆分：
#   build-common.sh  公共：pnpm install + build + 黑白名单裁剪 → target 整树 + build-meta.env
#   build-spk.sh     消费 target → 群晖 .spk 安装包
#   build-fpk.sh     【本脚本】消费 target → 飞牛 .fpk 安装包
#
# 【双链路】（2026-09-13 新增；默认行为不变）:
#   ./build-fpk.sh          默认：消费 build-common.sh 的 target（源码 monorepo 编译产物）
#   ./build-fpk.sh --npm    新增：消费 build-npm-fpk-app.sh 的 app_root（npm 装官方包，~100MiB）
#                           前置：先运行 ./build/FPK/build-npm-fpk-app.sh [VERSION]
#                           仅此参数走 npm 链路；SPK 与源码链路完全不受影响
#
# 用法:
#   ./build-fpk.sh [--npm]
#
# 产物:
#   build/staging/<APP_NAME>_x86-<FPK_VERSION>.fpk
#
# 关键设计（注释按本脚本职责重新整理）:
#   - 端口: proxy/dsh/container 读 build-config.yaml fpk: 段（默认 3080/3081/3082，
#     与 SPK 的 30800 段隔离）
#   - start.sh: 本脚本按 FPK 端口段生成（gen_start_sh，母版 build/start.sh.example；
#     首启构建逻辑已抽离 scripts/first-build-logic.sh 留档，完整预构建包免构建）
#   - app.tgz: gzip + --hard-dereference（硬链展开；软链保留，fnpack 官方支持 symlink）
#     ⚠ 条目无 ./ 前缀（用 find 顶层列表，fnOS 后端把 ./ 当字面路径 → 10111）
#   - 外层 .fpk: gzip；条目只列文件/软链不列目录（GNU tar 目录尾斜杠 → fnOS 解析错 → 10111）
#   - 门户 ui/ 内外两份都要（app.tgz 内供门户「打开」按钮取图标；外层供 install_start 安全扫描枚举 dir:ui）
#   - 外层 <appname>.sc 协议文件声明端口（manifest service_port 对应；缺失 → 10111）
#   - manifest: version=官方完整版本；checksum=app.tgz 的 MD5（实测）
#   - cmd 生命周期: 启停全代理到 bin/start.sh；username/groupname 必须小写
#===============================================================================
set -euo pipefail

# ── 本脚本引用的脚本/目录路径（常量；改路径只改这里，引用点一律用常量） ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # build/FPK/
WS="$(cd "$SCRIPT_DIR/../.." && pwd)"                        # 工作区根（脚本在 build/FPK/ 下）
BUILD_ROOT="$WS/build"
CONFIG_FILE="$SCRIPT_DIR/../build-config.yaml"               # 配置在 build/ 根
BUILD_META_DIR="$BUILD_ROOT/master-build"                    # 源码链路 target 元数据根（原 spk-build → master-build）
NPM_META_DIR="$BUILD_ROOT/master-build"                      # npm 链路 app 元数据根（同根目录，不同子目录）
NPM_APP_SCRIPT="$BUILD_ROOT/FPK/build-npm-fpk-app.sh"        # FPK npm 链路脚本（本目录）
EXCLUDES_FILE="$BUILD_ROOT/build-excludes.json"              # tar 排除规则（通用，build/ 根）

# ── 参数：--npm 走 npm 装包链路（默认源码 target 链路不变） ──
NPM_MODE=0
case "${1:-}" in
  --npm) NPM_MODE=1 ;;
  "") ;;
  *) echo "用法: $0 [--npm]" >&2; exit 1 ;;
esac

# ── 工作区分类目录（环境变量可覆盖，与 build-common.sh 一致） ──
D_ASSETS="${D_ASSETS:-$WS/build}"
D_BUILD="${D_BUILD:-$WS/build}"
D_STAGING="${D_STAGING:-$D_BUILD/staging}"
D_SCRIPTS="${D_SCRIPTS:-$WS/scripts}"

# ----------------------------------------------------------------------------
# build-config.yaml 解析（FPK 段覆盖 defaults：端口 + appname + 品牌元数据）
#   全部字段一律来自配置，脚本内不写死任何可变值（no-hardcode-config）
# ----------------------------------------------------------------------------
eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f) or {}
defaults = cfg.get('defaults') or {}
fpk = cfg.get('fpk') or {}
for k, v in {**defaults, **fpk}.items():
    if v is None:
        continue
    print(f'FPKCFG_{k.upper()}=\"{v}\"')
" 2>/dev/null || true)"
FPK_PROXY_PORT="${FPKCFG_PROXY_PORT:-3080}"
FPK_DSH_PORT="${FPKCFG_DSH_PORT:-3081}"
FPK_CONTAINER_PORT="${FPKCFG_CONTAINER_PORT:-3082}"

# ── 品牌 / 元数据（配置驱动；缺省值仅作最后兜底，正常一律命中配置） ──
CFG_APPNAME="${FPKCFG_APPNAME:-DeepSeekHarness-NAS}"
CFG_BRAND_NAME="${FPKCFG_BRAND_NAME:-$CFG_APPNAME}"
CFG_DISPLAY_NAME="${FPKCFG_DISPLAY_NAME:-DeepSeek Harness}"
CFG_TITLE="${FPKCFG_TITLE:-$CFG_DISPLAY_NAME}"
CFG_DESC="${FPKCFG_DESC:-}"
CFG_DESC_SHORT="${FPKCFG_DESC_SHORT:-$CFG_DISPLAY_NAME Web UI}"
CFG_MAINTAINER="${FPKCFG_MAINTAINER:-DeepSeek AI}"
CFG_MAINTAINER_URL="${FPKCFG_MAINTAINER_URL:-}"
CFG_DISTRIBUTOR="${FPKCFG_DISTRIBUTOR:-}"
CFG_DISTRIBUTOR_URL="${FPKCFG_DISTRIBUTOR_URL:-}"
CFG_OS_MIN_VERSION="${FPKCFG_OS_MIN_VERSION:-1.1.0}"
CFG_BRAND_VERSION_ORDER="${FPKCFG_BRAND_VERSION_ORDER:-dsh,npm}"
# 体积门禁（MB；0 = 不检查。任务① 验收口径 fpk≈100MiB，留余量设 200）
CFG_SIZE_LIMIT_MB="${FPKCFG_SIZE_LIMIT_MB:-200}"
# 共享区（@appshare）目录名：根路径由 TRIM_PKGVAR 自动推导，此处只定根下目录名
# ⚠ 必须用 "-" 而非 ":-"：:- 会把配置里的空串当成"未设置"而回退成默认值，
#   导致「配置留空=不创建」失效（实测踩过）。空 = 不创建，故默认就是空。
CFG_SHARE_WORKSPACE_DIR="${FPKCFG_SHARE_WORKSPACE_DIR-}"
CFG_SHARE_DATA_DIR="${FPKCFG_SHARE_DATA_DIR-}"

# ----------------------------------------------------------------------------
# 元数据（双链路：--npm 读 npm-meta.env，默认读 build-meta.env）
# ----------------------------------------------------------------------------
if [ "$NPM_MODE" = "1" ]; then
  _NPM_META="$(ls -1t "$NPM_META_DIR"/npm-app-*/npm-meta.env 2>/dev/null | head -1)"
  if [ -z "$_NPM_META" ] || [ ! -f "$_NPM_META" ]; then
    echo "✗ 未找到 npm-meta.env（请先运行 ./build/FPK/build-npm-fpk-app.sh [VERSION] 生成 npm 应用体）" >&2
    exit 1
  fi
  . "$_NPM_META"   # APP_NAME/APP_ID/APP_NAME_LOWER/PKG_VER/FPK_VERSION/SPK_VERSION/APP_ROOT
  [ -d "$APP_ROOT" ] || { echo "✗ npm app_root 缺失: $APP_ROOT" >&2; exit 1; }
  TARGET="$APP_ROOT"   # 后续应用体复制统一用 TARGET 变量
  WORK="$(dirname "$_NPM_META")"
  echo "使用 npm 应用体: $APP_ROOT（dsh $PKG_VER | FPK $FPK_VERSION | APP_NAME $APP_NAME）"
else
  _META="$(ls -1t "$BUILD_META_DIR"/build-*/build-meta.env 2>/dev/null | head -1)"
  if [ -z "$_META" ] || [ ! -f "$_META" ]; then
    echo "✗ 未找到 build-meta.env（请先运行 ./build-common.sh 生成 target）" >&2
    exit 1
  fi
  . "$_META"   # 提供 APP_NAME/APP_ID/APP_NAME_LOWER/PKG_VER/SPK_VERSION/FPK_VERSION/DESC/TARGET/WORK
  if [ ! -d "$TARGET" ] || [ ! -f "$TARGET/package.json" ]; then
    echo "✗ target 缺失或不完整: $TARGET（请先运行 ./build-common.sh）" >&2
    exit 1
  fi
  echo "使用 target : $TARGET（dsh $PKG_VER | FPK $FPK_VERSION | APP_NAME $APP_NAME）"
fi

# 排除规则（build-excludes.json dist 模式；条目带 ./ 前缀是 SPK 用，FPK 派生去前缀）
mapfile -t TAR_EXCLUDES < <(python3 -c "
import json
with open('$EXCLUDES_FILE') as f:
    cfg = json.load(f)
for x in cfg.get('dist', {}).get('excludes', []):
    if not x.startswith('_comment'):
        print(x)
" 2>/dev/null || true)
_FPK_EXCLUDES=()
for _x in "${TAR_EXCLUDES[@]}"; do
  _FPK_EXCLUDES+=("${_x/--exclude=.\//--exclude=}")
done

# ----------------------------------------------------------------------------
# start.sh 生成（FPK 端口段；母版占位符 → 配置值）
# ----------------------------------------------------------------------------
gen_start_sh() {
  local out="$1" proxy="$2" dsh="$3" cont="$4"
  sed -e "s|__PROXY_PORT__|${proxy}|g" \
      -e "s|__DSH_PORT__|${dsh}|g" \
      -e "s|__CONTAINER_PORT__|${cont}|g" \
      -e "s|__APP_NAME__|${APP_NAME}|g" \
      -e "s|__APP_ID__|${APP_ID}|g" \
      -e "s|__BRAND_NAME__|${CFG_BRAND_NAME}|g" \
      -e "s|__BRAND_VERSION_ORDER__|${CFG_BRAND_VERSION_ORDER}|g" \
      -e "s|__FPK_VERSION__|${FPK_VERSION}|g" \
      -e "s|__PORTAL_TITLE__|${CFG_TITLE}|g" \
      -e "s|__PORTAL_DESC__|${CFG_DESC_SHORT:-$CFG_DISPLAY_NAME Web UI}|g" \
      "$BUILD_ROOT/start.sh.example" > "$out"
  chmod +x "$out"
  if grep -qE "__PROXY_PORT__|__DSH_PORT__|__CONTAINER_PORT__|__APP_NAME__|__APP_ID__|__BRAND_NAME__|__BRAND_VERSION_ORDER__|__FPK_VERSION__|__PORTAL_TITLE__|__PORTAL_DESC__" "$out"; then
    echo "[!] start.sh 占位符未全部替换: $out" >&2; exit 1
  fi
}

#===============================================================================
# 一、FPK 应用体（target → app）
#===============================================================================
echo ""
echo "══════ FPK 打包（飞牛 fnOS x86）══════"
FPK_SRC="$WORK/fpk-src"
FPK_APP="$FPK_SRC/app"
rm -rf "$FPK_SRC"
mkdir -p "$FPK_APP"

# 6.1 应用体 = target 整树 + 飞牛门户 config + fpk 端口 start.sh
echo "▶ 复制 target → fpk 应用体"
# ⚠ 不能用 cp -a：target/node_modules/.pnpm 是 pnpm 深硬链目录，ZFS/CIFS 下 cp -a
#   递归复制深目录会报「目录非空/没有那个文件或目录」（实测踩坑）。
#   用 tar 管道 + --hard-dereference 把硬链接展开成真实文件，规避深目录复制失败。
( cd "$TARGET" && tar -cf - --hard-dereference . ) | ( cd "$FPK_APP" && tar -xf - )

echo "▶ 生成 fpk start.sh（端口 $FPK_PROXY_PORT/$FPK_DSH_PORT/$FPK_CONTAINER_PORT）"
gen_start_sh "$FPK_APP/bin/start.sh" "$FPK_PROXY_PORT" "$FPK_DSH_PORT" "$FPK_CONTAINER_PORT"

# var/ports 重写为 FPK 端口段（target 里可能是 SPK 段残留的 30800，必须覆盖；
# npm 布局 app_root 可能无 var/，先建目录保证可写）
mkdir -p "$FPK_APP/var"
echo "▶ 重写 fpk var/ports（$FPK_PROXY_PORT/$FPK_DSH_PORT/$FPK_CONTAINER_PORT）"
cat > "$FPK_APP/var/ports" <<PORTS_EOF
# FPK 端口配置（build-config.yaml fpk: 段驱动）
PROXY_PORT=${FPK_PROXY_PORT}
DSH_PORT=${FPK_DSH_PORT}
CONTAINER_PORT=${FPK_CONTAINER_PORT}
PORTS_EOF
echo "  ✓ fpk var/ports 已按 FPK 端口段重写"

# 飞牛门户 ui —— 两份都必须有，缺一不可：
#   ① app.tgz 内 <APPDIR>/ui：门户「打开」按钮与桌面图标按
#      /app-center-static/serviceicon/<APP>/ui/images/icon_{0}.png 从【应用目录】取，
#      app 体内没有 ui/ → 桌面图标空白且不出现「打开」按钮（2026-09-13 实机实测）。
#   ② fpk 外层 ui/：install_start 安全扫描会枚举外层 dir:ui。
#   type=url：门户点击直接跳转 URL 打开（非 iframe 内嵌）。
#   --key-id APP_NAME：FPK 键名须带连字符与 manifest desktop_applaunchname 对齐。
mkdir -p "$FPK_SRC/ui/images" "$FPK_APP/ui/images"
cp "$D_ASSETS/ui/images/"*.png "$FPK_SRC/ui/images/" 2>/dev/null || true
cp "$D_ASSETS/ui/images/"*.png "$FPK_APP/ui/images/" 2>/dev/null || true
"$FPK_APP/bin/start.sh" gen-portal --type url --key-prefix "" --all-users true --with-url true --key-id "$APP_NAME" \
  > "$FPK_SRC/ui/config"
cp "$FPK_SRC/ui/config" "$FPK_APP/ui/config"

# 外层 .sc 协议文件（manifest service_port 对应；缺失 → 后端 GetCloudDetail 读端口
# nil panic → CLI 10111。端口 = FPK 三段）
echo "▶ 生成外层 ${APP_NAME}.sc（端口 ${FPK_PROXY_PORT}/${FPK_DSH_PORT}/${FPK_CONTAINER_PORT}）"
cat > "$FPK_SRC/${APP_NAME}.sc" <<SC_EOF
[${APP_NAME}]
title="DeepSeek Harness"
desc="DeepSeek Harness Agent Harness"
port_forward="yes"
src.ports="${FPK_PROXY_PORT}/tcp,${FPK_DSH_PORT}/tcp,${FPK_CONTAINER_PORT}/tcp"
dst.ports="${FPK_PROXY_PORT}/tcp,${FPK_DSH_PORT}/tcp,${FPK_CONTAINER_PORT}/tcp"
SC_EOF

# app.tgz（gzip；--hard-dereference 硬链展开；软链保留——fnpack 官方支持 symlink）
echo "▶ 打包 app.tgz（gzip, 预构建产物包, ${#_FPK_EXCLUDES[@]} 条排除规则）"
# ⚠ 必须用 find 顶层列表而非 `-C dir .`：`. ` 让全部条目带 ./ 前缀，fnOS 后端解压时
#   把 ./ 当字面路径 → 顶层结构对不上 → GetCloudDetail 崩溃 10111
( cd "$FPK_APP" && find . -maxdepth 1 -mindepth 1 -printf '%f\n' > /tmp/fpk-toplist.$$ && \
  tar -czf "$FPK_SRC/app.tgz" --hard-dereference "${_FPK_EXCLUDES[@]}" --files-from=/tmp/fpk-toplist.$$ 2>/dev/null; \
  rm -f /tmp/fpk-toplist.$$ )
# app/（target 副本 ~600M）使命完成立即删除（build-artifact-cleanup：中间产物用完即删）
rm -rf "$FPK_APP"

#===============================================================================
# 二、manifest + cmd + config + wizard + ICON
#===============================================================================
# manifest（version=官方完整版本；checksum=app.tgz MD5 实测）
# ⚠ 禁止添加 changelog 字段！实测（2026-09-13）fnOS GetCloudDetail 解析未知字段
#   changelog → nil pointer → 10111。mod13 对照实验：仅删 changelog 一行即安装成功。
FPK_CHECKSUM="$(md5sum "$FPK_SRC/app.tgz" | awk '{print $1}')"
cat > "$FPK_SRC/manifest" <<EOF
appname               = ${APP_NAME}
version               = ${FPK_VERSION}
display_name          = ${CFG_DISPLAY_NAME}
platform              = x86
maintainer            = ${CFG_MAINTAINER}
maintainer_url        = ${CFG_MAINTAINER_URL}
distributor           = ${CFG_DISTRIBUTOR}
distributor_url       = ${CFG_DISTRIBUTOR_URL}
os_min_version        = ${CFG_OS_MIN_VERSION}
desktop_uidir         = ui
desktop_applaunchname = ${APP_NAME}.Application
service_port          = ${FPK_PROXY_PORT}
checkport             = false
ctl_stop              = true
desc                  = ${CFG_DESC}
source                = ${FPKCFG_SOURCE:-thirdparty}
wizard_dir            = wizard
checksum              = ${FPK_CHECKSUM}
EOF

# cmd 生命周期目录
mkdir -p "$FPK_SRC/cmd" "$FPK_SRC/config" "$FPK_SRC/wizard"

# cmd/main：start/stop/status/restart 全代理到 bin/start.sh
#   端口一律从 <app>/var/ports 读取（打包期由 build-config.yaml 落盘，不硬编码）
#   启停含兜底：stop 先优雅停再补杀残留；start 后做运行检测
cat > "$FPK_SRC/cmd/main" <<'EOF'
#!/bin/bash
APPNAME="__APP_NAME__"
if [ -z "${TRIM_APPDEST:-}" ]; then
  if [ -e "/var/apps/${APPNAME}/target" ]; then
    TRIM_APPDEST=$(readlink -f "/var/apps/${APPNAME}/target" 2>/dev/null || echo "/var/apps/${APPNAME}/target")
  else
    TRIM_APPDEST="/vol1/@appcenter/${APPNAME}"
  fi
fi
if [ -z "${TRIM_PKGVAR:-}" ]; then
  if [ -e "/var/apps/${APPNAME}/var" ]; then
    TRIM_PKGVAR=$(readlink -f "/var/apps/${APPNAME}/var" 2>/dev/null || echo "/var/apps/${APPNAME}/var")
  else
    TRIM_PKGVAR="/vol1/@appdata/${APPNAME}"
  fi
fi
mkdir -p "${TRIM_PKGVAR}" 2>/dev/null || true
LOG_FILE="${TRIM_PKGVAR}/${APPNAME}.log"
PID_FILE="${TRIM_PKGVAR}/${APPNAME}.pid"
log_msg(){ echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"; }

# ── 端口：优先读应用体自带 var/ports（打包期生成），缺失则回退包内默认 ──
PORT_FILE="${TRIM_APPDEST}/var/ports"
if [ -f "$PORT_FILE" ]; then
  . "$PORT_FILE"
fi
if [ -z "${PROXY_PORT:-}" ] || [ -z "${DSH_PORT:-}" ] || [ -z "${CONTAINER_PORT:-}" ]; then
  log_msg "错误：未找到 ${PORT_FILE}（端口应由打包时生成），无法确定服务端口"
  echo "✗ 未找到 ${PORT_FILE}，无法确定服务端口" >&2
  exit 1
fi

# ── 运行检测：DSH 端口在听 或 start.sh 进程在（两者其一即视为运行）──
running_dsh() {
  # 判定顺序：① DSH 端口在听（最可靠）→ ② 本应用 start.sh 进程在（按绝对路径精确匹配）
  # ⚠ 禁止宽松的 `ps -ef | grep start.sh`：会命中任何命令行里含 "start.sh" 的无关进程
  #   （含诊断命令自身），实测导致 status 恒判「运行中」→ 系统不再拉起服务（2026-09-13）。
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q ":${DSH_PORT} " && return 0
  elif command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":${DSH_PORT} " && return 0
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "${TRIM_APPDEST}/bin/start\.sh" >/dev/null 2>&1 && return 0
  fi
  return 1
}

start_process() {
  log_msg "Starting ${APPNAME}... (proxy=${PROXY_PORT} dsh=${DSH_PORT} container=${CONTAINER_PORT})"
  mkdir -p "${TRIM_PKGVAR}/logs" "${TRIM_PKGVAR}/data" 2>/dev/null || true
  export PATH="${TRIM_APPDEST}/bin:$PATH" HOME="${TRIM_APPDEST}"
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  # 给应用用户可写的私有 tmp（fnOS /tmp 无 sticky 且属 root，应用不可写）
  export TMPDIR="${TRIM_PKGVAR}/tmp" TMP="${TRIM_PKGVAR}/tmp" TEMP="${TRIM_PKGVAR}/tmp"
  mkdir -p "$TMPDIR" 2>/dev/null || true
  cd "${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" start \
    --proxy-port "$PROXY_PORT" \
    --dsh-port "$DSH_PORT" \
    --container-port "$CONTAINER_PORT" >> "${LOG_FILE}" 2>&1
  local rc=$?
  log_msg "start.sh rc=${rc}"
  sleep 3
  if ! running_dsh; then
    log_msg "启动后运行检测未通过（端口 ${DSH_PORT} 未监听）"
    return 1
  fi
  log_msg "运行检测通过"
  return 0
}

stop_process() {
  log_msg "Stopping ${APPNAME}..."
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" stop \
    --proxy-port "$PROXY_PORT" \
    --dsh-port "$DSH_PORT" \
    --container-port "$CONTAINER_PORT" >> "${LOG_FILE}" 2>&1 || true
  # 兜底：PID 文件残留进程 → 精确 TERM → 残留子进程 → KILL（先 TERM 后 KILL）
  # start.sh 把 PID 写在版本数据目录（<TRIM_PKGVAR>/<version>/<APPNAME>.pid），此处按同规则定位
  local _pidfile _pid
  for _pidfile in "${TRIM_PKGVAR}/${APPNAME}.pid" "${TRIM_PKGVAR}"/*/"${APPNAME}.pid"; do
    [ -f "$_pidfile" ] || continue
    _pid="$(tr -dc '0-9' < "$_pidfile" 2>/dev/null)"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      kill -TERM "$_pid" 2>/dev/null || true
      sleep 2
      kill -0 "$_pid" 2>/dev/null && { kill -KILL "$_pid" 2>/dev/null || true; }
    fi
    rm -f "$_pidfile" 2>/dev/null || true
  done
  pkill -f "bin\.js web" 2>/dev/null || true
  sleep 1
  pkill -9 -f "start\.sh" 2>/dev/null || true
  log_msg "Stopped"
  return 0
}

status_process() {
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" status > /dev/null 2>&1 && return 0
  running_dsh
}

case "$1" in
  start)   start_process && { echo "✓ 启动成功"; exit 0; } || { echo "✗ 启动失败（运行检测未通过）"; exit 1; } ;;
  stop)    stop_process; echo "✓ 已停止"; exit 0 ;;
  status)  status_process && { echo "✓ 服务运行中"; exit 0; } || { echo "✗ 服务未运行"; exit 3; } ;;
  restart) stop_process; sleep 2; start_process && { echo "✓ 重启成功"; exit 0; } || { echo "✗ 重启失败"; exit 1; } ;;
  *) echo "Usage: $0 {start|stop|status|restart}"; exit 1 ;;
esac
EOF

# cmd/common：生命周期公共变量（TRIM_* 由系统注入）
cat > "$FPK_SRC/cmd/common" <<'EOF'
#!/bin/bash
APPNAME="${TRIM_APPNAME:-__APP_NAME__}"
[ -z "${TRIM_APPDEST:-}" ] && TRIM_APPDEST="/vol1/@appcenter/${APPNAME}"
[ -z "${TRIM_PKGVAR:-}" ] && TRIM_PKGVAR="/vol1/@appdata/${APPNAME}"
export TRIM_APPDEST TRIM_PKGVAR APPNAME
load_variables_from_file(){ :; }
call_func(){ local fn="$1"; shift; type "$fn" >/dev/null 2>&1 && "$fn" "$@"; }
log_msg(){ echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${TRIM_PKGVAR}/${APPNAME}.log"; }
install_log="${TRIM_PKGVAR:-/tmp}/${APPNAME}.install.log"
EOF

# cmd/service-setup：服务定义 + 安装后初始化（工作区目录 + 权限）
#   端口从 <app>/var/ports 读取（打包期由 build-config.yaml 落盘）；启停一律带端口参数
cat > "$FPK_SRC/cmd/service-setup" <<EOF
#!/bin/bash
LOG_FILE="\${TRIM_PKGVAR}/__APP_NAME__.log"
PID_FILE="\${TRIM_PKGVAR}/__APP_NAME__.pid"
APP_DIR="\${TRIM_APPDEST}"
export PATH="\${APP_DIR}/bin:\$PATH" HOME="\${APP_DIR}"
# 应用用户可写的私有 tmp（fnOS /tmp 无 sticky 且属 root，应用不可写）
export TMPDIR="\${TRIM_PKGVAR}/tmp" TMP="\${TRIM_PKGVAR}/tmp" TEMP="\${TRIM_PKGVAR}/tmp"

# ── 端口：读应用体自带 var/ports（打包期生成），缺失则报错不放行 ──
PORT_FILE="\${APP_DIR}/var/ports"
[ -f "\${PORT_FILE}" ] && . "\${PORT_FILE}"
if [ -z "\${PROXY_PORT:-}" ] || [ -z "\${DSH_PORT:-}" ] || [ -z "\${CONTAINER_PORT:-}" ]; then
  echo "错误：未找到 \${PORT_FILE}（端口应由打包时生成），无法确定服务端口" >&2
  exit 1
fi

SERVICE_COMMAND="\${APP_DIR}/bin/start.sh start --proxy-port \${PROXY_PORT} --dsh-port \${DSH_PORT} --container-port \${CONTAINER_PORT}"
SVC_BACKGROUND=y
SVC_WRITE_PID=y
SVC_CWD="\${TRIM_PKGVAR}"
SVC_WAIT_TIMEOUT=15
service_postinst(){
  mkdir -p "\${TRIM_PKGVAR}/config" "\${TRIM_PKGVAR}/tmp" 2>/dev/null || true
  # ── 共享区（@appshare）映射：默认关闭，配置为空则整段不执行（零副作用）──
  # 开启方式：build-config.yaml 的 share_workspace_dir / share_data_dir 填目录名。
  # 路径全自动推导：TRIM_PKGVAR 形如 /vol2/@appdata/<APP>（fnOS 注入，卷随安装位置变），
  # 把其中的 @appdata 换成 @appshare 即共享区根 —— 不写卷号、不写应用名。
  SHARE_WORKSPACE="\${TRIM_PKGVAR/@appdata/@appshare}"
  SHARE_VOL="\${SHARE_WORKSPACE%%/@appshare*}"
  SHARE_WS_NAME="__SHARE_WORKSPACE_DIR__"
  SHARE_DATA_NAME="__SHARE_DATA_DIR__"
  if [ -n "\${SHARE_WS_NAME}\${SHARE_DATA_NAME}" ] && [ -n "\${SHARE_VOL}" ] && [ -d "\${SHARE_VOL}" ]; then
    DSH_OWNER="\${TRIM_USERNAME:-__APP_NAME__}:\${TRIM_GROUPNAME:-__APP_NAME__}"
    if [ -n "\${SHARE_WS_NAME}" ]; then
      mkdir -p "\${SHARE_WORKSPACE}/\${SHARE_WS_NAME}" 2>/dev/null || true
      chmod -R 777 "\${SHARE_WORKSPACE}/\${SHARE_WS_NAME}" 2>/dev/null || true
    fi
    if [ -n "\${SHARE_DATA_NAME}" ]; then
      mkdir -p "\${SHARE_WORKSPACE}/\${SHARE_DATA_NAME}" 2>/dev/null || true
      chmod -R 777 "\${SHARE_WORKSPACE}/\${SHARE_DATA_NAME}" 2>/dev/null || true
      [ -d "\${TRIM_PKGVAR}/\${SHARE_DATA_NAME}" ] && [ ! -L "\${TRIM_PKGVAR}/\${SHARE_DATA_NAME}" ] && { cp -a "\${TRIM_PKGVAR}/\${SHARE_DATA_NAME}/." "\${SHARE_WORKSPACE}/\${SHARE_DATA_NAME}/" 2>/dev/null || true; rm -rf "\${TRIM_PKGVAR}/\${SHARE_DATA_NAME}"; }
      ln -sfn "\${SHARE_WORKSPACE}/\${SHARE_DATA_NAME}" "\${TRIM_PKGVAR}/\${SHARE_DATA_NAME}" 2>/dev/null || true
    fi
    [ -e "\${SHARE_WORKSPACE}/.dsh" ] && { chown -R "\${DSH_OWNER}" "\${SHARE_WORKSPACE}/.dsh" 2>/dev/null || true; find "\${SHARE_WORKSPACE}/.dsh" -type d -exec chmod 700 {} + 2>/dev/null || true; find "\${SHARE_WORKSPACE}/.dsh" -type f -exec chmod 600 {} + 2>/dev/null || true; }
  fi
}
service_postupgrade(){ service_postinst; }
# 运行检测：DSH 端口在听 或 start.sh 进程在
service_running(){
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q ":\${DSH_PORT} " && return 0
  elif command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":\${DSH_PORT} " && return 0
  fi
  # 精确匹配本应用 start.sh 绝对路径（宽松 grep 会误命中无关进程）
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "\${APP_DIR}/bin/start\.sh" >/dev/null 2>&1 && return 0
  fi
  return 1
}
service_poststart(){
  sleep 3
  service_running || { echo "启动后运行检测未通过（端口 \${DSH_PORT} 未监听）" >> "\${LOG_FILE}" 2>/dev/null; return 1; }
  return 0
}
service_preuninst(){
  export TRIM_APPDEST="\${TRIM_APPDEST}" TRIM_PKGVAR="\${TRIM_PKGVAR}"
  "\${APP_DIR}/bin/start.sh" stop --proxy-port "\${PROXY_PORT}" --dsh-port "\${DSH_PORT}" --container-port "\${CONTAINER_PORT}" >> "\${TRIM_PKGVAR}/__APP_NAME__.log" 2>&1 || true
  rm -f "\${PID_FILE}" 2>/dev/null || true
}
service_poststop(){ service_preuninst; }
EOF

# cmd/installer：入口（source common + service-setup + 调用钩子）
cat > "$FPK_SRC/cmd/installer" <<'EOF'
#!/bin/bash
COMMON=$(dirname $0)"/common"
[ -r "${COMMON}" ] && . "${COMMON}"
SVC_SETUP=$(dirname $0)"/service-setup"
[ -r "${SVC_SETUP}" ] && . "${SVC_SETUP}"
load_variables_from_file "${INST_VARIABLES}"
call_func "initialize_variables" install_log
EOF

# 生命周期钩子：官方薄壳结构（fnOS 只执行薄壳，自包含大脚本实测不被执行——
#   2026-09-13 skill 实测铁证 + 2026-09-22 飞牛真机复验：数据保留但无 trace）。
# 每个钩子 = source config/common/package + 调同名函数（函数定义在 package）。
for hook in install_init uninstall_init upgrade_init config_init config_callback uninstall_callback upgrade_callback; do
  cat > "$FPK_SRC/cmd/$hook" <<'SHELL'
#!/bin/bash

. $(dirname $0)"/config"
. $(dirname $0)"/common"
. $(dirname $0)"/package"
$(basename $0) > $TRIM_TEMP_LOGFILE
SHELL
done

# cmd/package：生命周期同名函数框架（官方薄壳链的第三层，钩子第二行调这里）
#   install_callback：预建版本数据目录（/vol1/@appdata 属 root，应用用户无权限自建）
#   uninstall_callback：消费 wizard/uninstall 的 wizard_delete_data —— true=彻底删除，
#                        false/缺省=保留数据（2026-09-22 修复：旧自包含版本不被执行）
cat > "$FPK_SRC/cmd/package" <<'SHELL'
#!/bin/bash

# 读 wizard 表单持久化值（installer-variables 文件；fnOS 卸载向导选择写这里）
load_variables_from_file() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && . "$f" 2>/dev/null || true
}

# 版本号：与 bin/start.sh 的 resolve_pkg_version 一致（dsh 包 → npm 产物 → 顶层）
#   ⚠ APP_DIR 不得依赖 TRIM_APPDEST 注入（fnOS 安装/卸载期实测为空→回退 /vol1 错位）；
#     必须像 cmd/main 一样经 /var/apps/<APP>/target 软链解析真实安装位置（实测 /vol2）。
_app_dir() {
  if [ -n "${TRIM_APPDEST:-}" ]; then
    printf '%s' "${TRIM_APPDEST}"
  elif [ -e "/var/apps/${APPNAME}/target" ]; then
    readlink -f "/var/apps/${APPNAME}/target" 2>/dev/null
  else
    printf '%s' "/vol1/@appcenter/${APPNAME}"
  fi
}
_version_from() {
  local src="$1" dir="$2" f v
  case "$src" in
    dsh)
      for f in "$dir/node_modules/@deepseek-ai/dsh/package.json" \
               "$dir/node_modules/node_modules/@deepseek-ai/dsh/package.json" \
               "$dir/apps/cli/package.json"; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
      done ;;
    npm)
      for f in "$dir/node_modules/@deepseek-ai/dsh-client-ui-sidebar/lib/client.js" \
               "$dir/node_modules/node_modules/@deepseek-ai/dsh-client-ui-sidebar/lib/client.js"; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/.*function localBuildVersion()[^{]*{[[:space:]]*return[[:space:]]*`\([^`]*\)`.*/\1/p' "$f" 2>/dev/null | head -1)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
      done ;;
    top)
      f="$dir/package.json"
      [ -f "$f" ] && sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1 ;;
  esac
  return 0
}

install_init() { exit 0; }

install_callback() {
  # 执行痕迹（写应用数据目录而非 /tmp：fnOS /tmp 属 root 且无 sticky，应用用户写不进）
  {
    echo "[install_callback] $(date '+%H:%M:%S') uid=$(id -u) user=$(id -un) TRIM_APPDEST=${TRIM_APPDEST:-<空>} TRIM_PKGVAR=${TRIM_PKGVAR:-<空>}"
  } >> "${TRIM_PKGVAR:-/var/apps/${APPNAME}}/install-callback.trace" 2>/dev/null || true
  local APP_DIR; APP_DIR="$(_app_dir)"
  local VERSION=""
  for _s in __BRAND_VERSION_ORDER_COMMA__ top; do
    VERSION="$(_version_from "$_s" "$APP_DIR")"
    [ -n "$VERSION" ] && break
  done
  [ -z "$VERSION" ] && VERSION="__FPK_VERSION__"
  # 预建版本数据目录（安装期 /vol1/@appdata 属 root，应用用户无权限自建）
  if [ -n "$VERSION" ]; then
    mkdir -p "${TRIM_PKGVAR:-/vol1/@appdata/${APPNAME}}/${VERSION}" 2>/dev/null || true
  fi
  exit 0
}

uninstall_init() { exit 0; }

uninstall_callback() {
  # 执行痕迹（真机验证 fnOS 是否执行本钩子 + 选项是否传达）
  {
    echo "[uninstall_callback] $(date '+%H:%M:%S') uid=$(id -u) user=$(id -un) TRIM_PKGVAR=${TRIM_PKGVAR:-<空>}"
  } >> "${TRIM_PKGVAR:-/var/apps/${APPNAME}}/uninstall-callback.trace" 2>/dev/null || true
  # wizard 卸载选项（保留/彻底删除）：值经 installer-variables 持久化（环境变量双通道兼容）
  local DELETE_DATA="${wizard_delete_data:-${WIZARD_DELETE_DATA:-}}"
  if [ -z "$DELETE_DATA" ]; then
    load_variables_from_file "${INST_VARIABLES:-/var/apps/${APPNAME}/etc/installer-variables}"
    DELETE_DATA="${wizard_delete_data:-}"
  fi
  local APP_DIR; APP_DIR="$(_app_dir)"
  local VERSION=""
  for _s in __BRAND_VERSION_ORDER_COMMA__ top; do
    VERSION="$(_version_from "$_s" "$APP_DIR")"
    [ -n "$VERSION" ] && break
  done
  [ -z "$VERSION" ] && VERSION="__FPK_VERSION__"
  {
    echo "[uninstall_callback] wizard_delete_data=${DELETE_DATA:-<空>} VERSION=${VERSION:-<空>}"
  } >> "${TRIM_PKGVAR:-/var/apps/${APPNAME}}/uninstall-callback.trace" 2>/dev/null || true
  if [ "$DELETE_DATA" = "true" ]; then
    # 用户选择彻底删除：只删本版本数据目录；父目录空则删父（仅剩一个版本时父目录即被删）
    local PKG_ROOT="${TRIM_PKGVAR:-/vol1/@appdata/${APPNAME}}"
    if [ -n "$VERSION" ] && [ -d "$PKG_ROOT/$VERSION" ]; then
      rm -rf "$PKG_ROOT/$VERSION" 2>/dev/null
    fi
    if [ -d "$PKG_ROOT" ] && [ -z "$(ls -A "$PKG_ROOT" 2>/dev/null)" ]; then
      rm -rf "$PKG_ROOT" 2>/dev/null
    fi
  else
    {
      echo "[uninstall_callback] 保留数据（wizard_delete_data=${DELETE_DATA:-<空>}）: ${TRIM_PKGVAR:-/vol1/@appdata/${APPNAME}}/${VERSION}"
    } >> "${TRIM_PKGVAR:-/var/apps/${APPNAME}}/uninstall-callback.trace" 2>/dev/null || true
  fi
  exit 0
}

upgrade_init() { exit 0; }

upgrade_callback() { exit 0; }

config_init() { exit 0; }

config_callback() { exit 0; }
SHELL


chmod -R 755 "$FPK_SRC/cmd"/

# config/privilege + resource（privilege 必须含 username/groupname 且小写——
#   大写会生成大写系统用户导致 root 问题；run-as=package 走应用用户）
mkdir -p "$FPK_SRC/config"
cat > "$FPK_SRC/config/privilege" <<EOF
{
    "defaults": {
        "run-as": "package"
    },
    "username": "${APP_NAME_LOWER}",
    "groupname": "${APP_NAME_LOWER}"
}
EOF
if [ -f "$D_ASSETS/conf/resource" ]; then
  sed "s/deepseek-harness-nas/${APP_NAME_LOWER}/g; s/DeepSeekHarness-NAS/${APP_NAME_LOWER}/g" "$D_ASSETS/conf/resource" > "$FPK_SRC/config/resource" 2>/dev/null || \
    printf '{"data-share":{"shares":[{"name":"%s","permission":{"rw":["%s"]}}]}}' "$APP_NAME" "$APP_NAME_LOWER" > "$FPK_SRC/config/resource"
else
  printf '{"data-share":{"shares":[{"name":"%s","permission":{"rw":["%s"]}}]}}' "$APP_NAME" "$APP_NAME_LOWER" > "$FPK_SRC/config/resource"
fi

# wizard（安装向导页；install 一页 tips + uninstall 卸载确认）
cat > "$FPK_SRC/wizard/install" <<EOF
[
    {
        "stepTitle": "DeepSeek Harness 安装向导",
        "items": [
            {
                "type": "tips",
                "helpText": "<div style='font-size:15px;line-height:1.7;color:#1e293b;'><h3 style='margin:0 0 10px 0;color:#0284c7;font-size:18px;'>🎉 欢迎使用 DeepSeek Harness</h3><p>DeepSeek Harness (DSH) 是 DeepSeek AI 官方开源的 Agent 框架。v${SPK_VERSION}（内嵌 dsh ${FPK_VERSION}），门户打开自动携带 token 免密登录。</p></div>"
            }
        ]
    }
]
EOF
cat > "$FPK_SRC/wizard/uninstall" <<'EOF'
[
    {
        "stepTitle": "卸载确认",
        "items": [
            {
                "type": "tips",
                "helpText": "您即将卸载 DeepSeek Harness。请选择是否保留您的会话记录和模型配置数据："
            },
            {
                "type": "radio",
                "field": "wizard_delete_data",
                "label": "数据保留选项",
                "initValue": "false",
                "options": [
                    {
                        "label": "保留数据（推荐）- 再次安装时可直接恢复所有会话和配置",
                        "value": "false"
                    },
                    {
                        "label": "彻底删除所有数据（不可恢复）",
                        "value": "true"
                    }
                ]
            }
        ]
    }
]
EOF
# ⚠ 禁止把 wizard/uninstall 写成空数组 []：实测 fnOS GetCloudDetail 解析 WizardData 遇空数组 → nil panic → 10111（2026-09-13 exp-j 对照实验锁定：仅换 uninstall 为完整 JSON 即装成功）

# ICON（透明化处理后）
cp "$D_ASSETS/PACKAGE_ICON.PNG" "$FPK_SRC/ICON.PNG"
cp "$D_ASSETS/PACKAGE_ICON_256.PNG" "$FPK_SRC/ICON_256.PNG"

#===============================================================================
# 三、组装外层 fpk（gzip）
#===============================================================================
# cmd 内占位符统一替换为实际配置值（品牌顺序 / 版本兜底 / 应用名 / 共享区目录名）
sed -i "s/__APP_NAME__/${APP_NAME}/g" "$FPK_SRC/cmd/"* 2>/dev/null || true
sed -i "s/__BRAND_VERSION_ORDER_COMMA__/${CFG_BRAND_VERSION_ORDER//,/ }/g; s/__FPK_VERSION__/${FPK_VERSION}/g" "$FPK_SRC/cmd/"* 2>/dev/null || true
sed -i "s|__SHARE_WORKSPACE_DIR__|${CFG_SHARE_WORKSPACE_DIR}|g; s|__SHARE_DATA_DIR__|${CFG_SHARE_DATA_DIR}|g" "$FPK_SRC/cmd/"* 2>/dev/null || true
if grep -rl "__APP_NAME__\|__BRAND_VERSION_ORDER_COMMA__\|__FPK_VERSION__\|__SHARE_WORKSPACE_DIR__\|__SHARE_DATA_DIR__" "$FPK_SRC/cmd/" 2>/dev/null | grep -q .; then
  echo "[!] cmd 占位符未全部替换" >&2; exit 1
fi
OUT_FPK="$D_STAGING/${APP_NAME}_x86-${FPK_VERSION}.fpk"
# ⚠ staging 是 gitignore 的产物目录，CI 全新 checkout 不存在 → tar 写不进去
#   报 exit code 2（stderr 被 2>/dev/null 吞掉，只留一句 exit 2，极难定位）。
mkdir -p "$D_STAGING"
echo "▶ 组装外层 FPK → $OUT_FPK"
# ⚠ 条目必须与 fnpack 官方格式一致：无 ./ 前缀、无目录尾斜杠条目
#   find 只列文件/软链（避开 GNU tar 给目录自动补 `/`）；排除 app/（内容已进 app.tgz）
# ⚠ 不吞 tar 的 stderr：曾因 2>/dev/null 把「目标目录不存在（tar exit 2）」的真实
#   报错吞掉，CI 日志只剩一句 "exit code 2"，排查耗时。宁可日志吵一点。
( cd "$FPK_SRC" && find . -path ./app -prune -o \( -type f -o -type l \) -printf '%P\n' > /tmp/fpk-outer-list.$$ \
  && tar -cf "${OUT_FPK}.tar" --files-from=/tmp/fpk-outer-list.$$; rm -f /tmp/fpk-outer-list.$$ \
  && gzip -9 -f "${OUT_FPK}.tar" && mv "${OUT_FPK}.tar.gz" "$OUT_FPK" )

sync   # CIFS 元数据滞后
_FPK_SIZE_MB="$(du -m --apparent-size "$OUT_FPK" 2>/dev/null | cut -f1)"
echo "  ✅ FPK: $OUT_FPK ($(du -h --apparent-size "$OUT_FPK" | cut -f1) | MD5 $(md5sum "$OUT_FPK" | awk '{print $1}'))"

# 体积门禁（阈值来自 build-config.yaml size_limit_mb；0 = 不检查）
if [ "${CFG_SIZE_LIMIT_MB:-0}" != "0" ] && [ -n "$_FPK_SIZE_MB" ] && [ "$_FPK_SIZE_MB" -gt "$CFG_SIZE_LIMIT_MB" ]; then
  echo "[!] 体积门禁未通过：$_FPK_SIZE_MB MB > ${CFG_SIZE_LIMIT_MB} MB（阈值 size_limit_mb in build-config.yaml）" >&2
  echo "    产物已生成但未达标，请先裁剪（build/FPK/build-fpk.sh 消费的 target 重新跑 build-common.sh 纯白名单裁剪）后再发布。" >&2
  exit 1
fi

#===============================================================================
# 四、汇总
#===============================================================================
echo ""
echo "════════════════════════════════════════════════"
echo "✅ FPK 构建完成（产物已放入暂存区，尚未验证）"
echo "  FPK   : $OUT_FPK"
echo "  体积  : $(du -h --apparent-size "$OUT_FPK" | cut -f1)（门禁上限 ${CFG_SIZE_LIMIT_MB} MB）"
echo "  版本  : 官方 $PKG_VER | FPK $FPK_VERSION"
echo "  名牌  : ${CFG_BRAND_NAME} + 版本号（优先级 ${CFG_BRAND_VERSION_ORDER}）"
echo "  端口  : $FPK_PROXY_PORT / $FPK_DSH_PORT / $FPK_CONTAINER_PORT（var/ports 下发）"
echo "────────────────────────────────────────────────"
echo "发布目录 $D_STAGING 只放暂存；实装验证后执行:"
echo "  scripts/promote-release.sh <包文件名>"
echo "════════════════════════════════════════════════"