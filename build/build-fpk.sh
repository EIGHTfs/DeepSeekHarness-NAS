#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — FPK 打包脚本（飞牛 fnOS x86）
#===============================================================================
# 【三脚本分工】2026-09-13 从原 build.sh（spk+fpk 混合 1216 行）拆分：
#   build-common.sh  公共：pnpm install + build + 黑白名单裁剪 → target 整树 + build-meta.env
#   build-spk.sh     消费 target → 群晖 .spk 安装包
#   build-fpk.sh     【本脚本】消费 target → 飞牛 .fpk 安装包
#
# 用法:
#   ./build-fpk.sh
#   （无参数。所有配置读 build-config.yaml + build-meta.env；
#     前置：先运行 ./build-common.sh 生成 target）
#
# 产物:
#   build/staging/<APP_NAME>_<FPK_VERSION>-dist_x86.fpk
#
# 关键设计（注释按本脚本职责重新整理）:
#   - 端口: proxy/dsh/container 读 build-config.yaml fpk: 段（默认 3080/3081/3082，
#     与 SPK 的 30800 段隔离）
#   - start.sh: 本脚本按 FPK 端口段生成（gen_start_sh，母版 scripts/start.sh.example；
#     首启构建逻辑已抽离 scripts/first-build-logic.sh 留档，完整预构建包免构建）
#   - app.tgz: gzip + --hard-dereference（硬链展开；软链保留，fnpack 官方支持 symlink）
#     ⚠ 条目无 ./ 前缀（用 find 顶层列表，fnOS 后端把 ./ 当字面路径 → 10111）
#   - 外层 .fpk: gzip；条目只列文件/软链不列目录（GNU tar 目录尾斜杠 → fnOS 解析错 → 10111）
#   - 门户 ui/ 只放外层（app.tgz 内不带 ui/；install_start 安全扫描枚举外层 dir:ui）
#   - 外层 <appname>.sc 协议文件声明端口（manifest service_port 对应；缺失 → 10111）
#   - manifest: version=官方完整版本；checksum=app.tgz 的 MD5（实测）
#   - cmd 生命周期: 启停全代理到 bin/start.sh；username/groupname 必须小写
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/build-config.yaml"

# ── 工作区分类目录（环境变量可覆盖，与 build-common.sh 一致） ──
D_ASSETS="${D_ASSETS:-$WS/build}"
D_BUILD="${D_BUILD:-$WS/build}"
D_STAGING="${D_STAGING:-$D_BUILD/staging}"
D_SCRIPTS="${D_SCRIPTS:-$WS/scripts}"

# ----------------------------------------------------------------------------
# build-config.yaml 解析（FPK 段覆盖 defaults：端口 + appname）
# ----------------------------------------------------------------------------
eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f) or {}
defaults = cfg.get('defaults') or {}
fpk = cfg.get('fpk') or {}
for k, v in {**defaults, **fpk}.items():
    print(f'FPKCFG_{k.upper()}=\"{v}\"')
" 2>/dev/null || true)"
FPK_PROXY_PORT="${FPKCFG_PROXY_PORT:-3080}"
FPK_DSH_PORT="${FPKCFG_DSH_PORT:-3081}"
FPK_CONTAINER_PORT="${FPKCFG_CONTAINER_PORT:-3082}"

# ----------------------------------------------------------------------------
# target 与元数据（build-common.sh 产物）
# ----------------------------------------------------------------------------
_META="$(ls -1t "$D_BUILD"/spk-build/build-*/build-meta.env 2>/dev/null | head -1)"
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

# 排除规则（build-excludes.json dist 模式；条目带 ./ 前缀是 SPK 用，FPK 派生去前缀）
EXCLUDES_FILE="$SCRIPT_DIR/build-excludes.json"
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
      "$D_SCRIPTS/start.sh.example" > "$out"
  chmod +x "$out"
  if grep -q "__PROXY_PORT__\|__DSH_PORT__\|__CONTAINER_PORT__\|__APP_NAME__\|__APP_ID__" "$out"; then
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
cp -a "$TARGET/." "$FPK_APP/"

echo "▶ 生成 fpk start.sh（端口 $FPK_PROXY_PORT/$FPK_DSH_PORT/$FPK_CONTAINER_PORT）"
gen_start_sh "$FPK_APP/bin/start.sh" "$FPK_PROXY_PORT" "$FPK_DSH_PORT" "$FPK_CONTAINER_PORT"

# var/ports 重写为 FPK 端口段（target 里可能是 SPK 段残留的 30800，必须覆盖）
echo "▶ 重写 fpk var/ports（$FPK_PROXY_PORT/$FPK_DSH_PORT/$FPK_CONTAINER_PORT）"
cat > "$FPK_APP/var/ports" <<PORTS_EOF
# FPK 端口配置（build-config.yaml fpk: 段驱动）
PROXY_PORT=${FPK_PROXY_PORT}
DSH_PORT=${FPK_DSH_PORT}
CONTAINER_PORT=${FPK_CONTAINER_PORT}
PORTS_EOF
echo "  ✓ fpk var/ports 已按 FPK 端口段重写"

# 飞牛门户 config（$FPK_SRC/ui，fpk 外层；app.tgz 内不放 ui/）：
#   ui/config 由 start.sh gen-portal 生成（iframe 型、键名无 SYNO.SDS. 前缀）
#   --key-id APP_NAME：FPK 键名须带连字符与 manifest desktop_applaunchname 对齐
mkdir -p "$FPK_SRC/ui/images"
cp "$D_ASSETS/ui/images/"*.png "$FPK_SRC/ui/images/" 2>/dev/null || true
"$FPK_APP/bin/start.sh" gen-portal --type iframe --key-prefix "" --all-users true --with-url true --key-id "$APP_NAME" \
  > "$FPK_SRC/ui/config"
# ui/ 只在 fpk 外层，app 体内不留（避免内外重复）
rm -rf "$FPK_APP/ui"

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
FPK_CHECKSUM="$(md5sum "$FPK_SRC/app.tgz" | awk '{print $1}')"
cat > "$FPK_SRC/manifest" <<EOF
appname               = ${APP_NAME}
version               = ${FPK_VERSION}
display_name          = DeepSeek Harness
platform              = x86
maintainer            = DeepSeek AI
maintainer_url        = https://github.com/deepseek-ai/deepseek-harness
distributor           = EIGHTfs
distributor_url       = https://github.com/EIGHTfs/DeepSeekHarness-NAS
os_min_version        = 1.1.0
desktop_uidir         = ui
desktop_applaunchname = ${APP_NAME}.Application
service_port          = ${FPK_PROXY_PORT}
checkport             = false
ctl_stop              = true
desc                  = DeepSeek AI 官方开源的 Agent Harness（智能体框架），飞牛 fnOS 原生应用。版本号与官方 dsh 同步（${FPK_VERSION}），门户打开自动携带 token 免密登录。
changelog             = v${SPK_VERSION}（内嵌 dsh ${FPK_VERSION}）：品牌 DeepSeekHarness-NAS；版本号直接使用官方版本（不省略）；飞牛门户打开自动带 token（反代 302 + SameSite=Lax）；代理日志保留（/tmp/dsh-proxy.log）。
source                = thirdparty
wizard_dir            = wizard
checksum              = ${FPK_CHECKSUM}
EOF

# cmd 生命周期目录
mkdir -p "$FPK_SRC/cmd" "$FPK_SRC/config" "$FPK_SRC/wizard"

# cmd/main：start/stop/status/restart 全代理到 bin/start.sh
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
log_msg(){ echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"; }

start_process() {
  log_msg "Starting ${APPNAME}..."
  export PATH="${TRIM_APPDEST}/bin:$PATH" HOME="${TRIM_APPDEST}"
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  cd "${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" start >> "${LOG_FILE}" 2>&1
  local rc=$?
  log_msg "start.sh rc=${rc}"
  return ${rc}
}
stop_process() {
  log_msg "Stopping ${APPNAME}..."
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" stop >> "${LOG_FILE}" 2>&1
  return 0
}
status_process() {
  export TRIM_APPDEST="${TRIM_APPDEST}" TRIM_PKGVAR="${TRIM_PKGVAR}"
  "${TRIM_APPDEST}/bin/start.sh" status > /dev/null 2>&1
  return $?
}
case "$1" in
  start)   start_process && { echo "✓ 启动成功"; exit 0; } || { echo "✗ 启动失败"; exit 1; } ;;
  stop)    stop_process; echo "✓ 已停止"; exit 0 ;;
  status)  status_process && echo "✓ 服务运行中" || { echo "✗ 服务未运行"; exit 3; } ;;
  restart) stop_process; sleep 1; start_process && { echo "✓ 重启成功"; exit 0; } || { echo "✗ 重启失败"; exit 1; } ;;
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
cat > "$FPK_SRC/cmd/service-setup" <<EOF
#!/bin/bash
LOG_FILE="\${TRIM_PKGVAR}/__APP_NAME__.log"
PID_FILE="\${TRIM_PKGVAR}/__APP_NAME__.pid"
APP_DIR="\${TRIM_APPDEST}"
export PATH="\${APP_DIR}/bin:\$PATH" HOME="\${APP_DIR}"
SERVICE_COMMAND="\${APP_DIR}/bin/start.sh start"
SVC_BACKGROUND=y
SVC_WRITE_PID=y
SVC_CWD="\${TRIM_PKGVAR}"
SVC_WAIT_TIMEOUT=15
service_postinst(){
  mkdir -p "\${TRIM_PKGVAR}/config" 2>/dev/null || true
  SHARE_WORKSPACE="/vol1/@appshare/__APP_NAME__"
  if [ -d "/vol1" ]; then
    mkdir -p "\${SHARE_WORKSPACE}/workspace" "\${SHARE_WORKSPACE}/data" 2>/dev/null || true
    chmod -R 777 "\${SHARE_WORKSPACE}/workspace" "\${SHARE_WORKSPACE}/data" 2>/dev/null || true
    DSH_OWNER="\${TRIM_USERNAME:-__APP_NAME__}:\${TRIM_GROUPNAME:-__APP_NAME__}"
    [ -e "\${SHARE_WORKSPACE}/.dsh" ] && { chown -R "\${DSH_OWNER}" "\${SHARE_WORKSPACE}/.dsh" 2>/dev/null || true; find "\${SHARE_WORKSPACE}/.dsh" -type d -exec chmod 700 {} + 2>/dev/null || true; find "\${SHARE_WORKSPACE}/.dsh" -type f -exec chmod 600 {} + 2>/dev/null || true; }
    [ -d "\${TRIM_PKGVAR}/data" ] && [ ! -L "\${TRIM_PKGVAR}/data" ] && { cp -a "\${TRIM_PKGVAR}/data/." "\${SHARE_WORKSPACE}/data/" 2>/dev/null || true; rm -rf "\${TRIM_PKGVAR}/data"; }
    ln -sfn "\${SHARE_WORKSPACE}" "\${TRIM_PKGVAR}/data" 2>/dev/null || true
  fi
}
service_postupgrade(){ service_postinst; }
service_preuninst(){
  export TRIM_APPDEST="\${TRIM_APPDEST}" TRIM_PKGVAR="\${TRIM_PKGVAR}"
  "\${APP_DIR}/bin/start.sh" stop >> "\${TRIM_PKGVAR}/__APP_NAME__.log" 2>&1 || true
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

# 空壳钩子
for hook in install_init uninstall_init upgrade_init config_init config_callback uninstall_callback upgrade_callback; do
  printf '#!/bin/bash\n### %s hook\nif [ -r "$(dirname $0)/common" ]; then . "$(dirname $0)/common"; fi\nexit 0\n' "$hook" > "$FPK_SRC/cmd/$hook"
done

# install_callback：预建版本数据目录（/vol1/@appdata 属 root，应用用户无权限自建）
cat > "$FPK_SRC/cmd/install_callback" <<'EOF'
#!/bin/bash
APP_USER="${TRIM_APPNAME:-__APP_NAME__}"
PKG_ROOT="${TRIM_PKGVAR:-/vol1/@appdata/__APP_NAME__}"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TRIM_APPDEST:-/vol1/@appcenter/__APP_NAME__}/package.json" 2>/dev/null | head -1)"
[ -z "$VERSION" ] && VERSION="0.1.5-alpha.1"
mkdir -p "${PKG_ROOT}/${VERSION}" 2>/dev/null || exit 0
chown -R "${APP_USER}:${APP_USER}" "${PKG_ROOT}" 2>/dev/null || true
chmod 700 "${PKG_ROOT}/${VERSION}" 2>/dev/null || true
exit 0
EOF

# uninstall_callback：只删本版本数据目录；父目录空则删父
cat > "$FPK_SRC/cmd/uninstall_callback" <<'EOF'
#!/bin/bash
APP_USER="${TRIM_APPNAME:-__APP_NAME__}"
PKG_ROOT="${TRIM_PKGVAR:-/vol1/@appdata/__APP_NAME__}"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TRIM_APPDEST:-/vol1/@appcenter/__APP_NAME__}/package.json" 2>/dev/null | head -1)"
[ -z "$VERSION" ] && VERSION="0.1.5-alpha.1"
if [ -n "$VERSION" ] && [ -d "$PKG_ROOT/$VERSION" ]; then
  rm -rf "$PKG_ROOT/$VERSION" 2>/dev/null
fi
if [ -d "$PKG_ROOT" ] && [ -z "$(ls -A "$PKG_ROOT" 2>/dev/null)" ]; then
  rm -rf "$PKG_ROOT" 2>/dev/null
fi
exit 0
EOF

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

# wizard（安装向导页；install 一页 tips + uninstall 空数组）
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
printf '[]' > "$FPK_SRC/wizard/uninstall"

# ICON（透明化处理后）
cp "$D_ASSETS/PACKAGE_ICON.PNG" "$FPK_SRC/ICON.PNG"
cp "$D_ASSETS/PACKAGE_ICON_256.PNG" "$FPK_SRC/ICON_256.PNG"

#===============================================================================
# 三、组装外层 fpk（gzip）
#===============================================================================
# cmd 内占位符统一替换为实际 APP_NAME
sed -i "s/__APP_NAME__/${APP_NAME}/g" "$FPK_SRC/cmd/"* 2>/dev/null || true
OUT_FPK="$D_STAGING/${APP_NAME}_${FPK_VERSION}-dist_x86.fpk"
echo "▶ 组装外层 FPK → $OUT_FPK"
# ⚠ 条目必须与 fnpack 官方格式一致：无 ./ 前缀、无目录尾斜杠条目
#   find 只列文件/软链（避开 GNU tar 给目录自动补 `/`）；排除 app/（内容已进 app.tgz）
( cd "$FPK_SRC" && find . -path ./app -prune -o \( -type f -o -type l \) -printf '%P\n' > /tmp/fpk-outer-list.$$ \
  && tar -cf "${OUT_FPK}.tar" --files-from=/tmp/fpk-outer-list.$$ 2>/dev/null; rm -f /tmp/fpk-outer-list.$$ \
  && gzip -9 -f "${OUT_FPK}.tar" && mv "${OUT_FPK}.tar.gz" "$OUT_FPK" )

sync   # CIFS 元数据滞后
echo "  ✅ FPK: $OUT_FPK ($(du -h --apparent-size "$OUT_FPK" | cut -f1) | MD5 $(md5sum "$OUT_FPK" | awk '{print $1}'))"

#===============================================================================
# 四、汇总
#===============================================================================
echo ""
echo "════════════════════════════════════════════════"
echo "✅ FPK 构建完成（产物已放入暂存区，尚未验证）"
echo "  FPK   : $OUT_FPK"
echo "  版本  : 官方 $PKG_VER | FPK $FPK_VERSION"
echo "  端口  : $FPK_PROXY_PORT / $FPK_DSH_PORT / $FPK_CONTAINER_PORT"
echo "────────────────────────────────────────────────"
echo "发布目录 $D_STAGING 只放暂存；实装验证后执行:"
echo "  scripts/promote-release.sh <包文件名>"
echo "════════════════════════════════════════════════"