#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — SPK 打包脚本（群晖 DSM x86_64）
#===============================================================================
# 【三脚本分工】2026-09-13 从原 build.sh（spk+fpk 混合 1216 行）拆分：
#   build-common.sh  公共：pnpm install + build + 黑白名单裁剪 → target 整树 + build-meta.env
#   build-spk.sh     【本脚本】消费 target → 群晖 .spk 安装包
#   build-fpk.sh     消费 target → 飞牛 .fpk 安装包
#
# 用法:
#   ./build-spk.sh
#   （无参数。所有配置读 build-config.yaml + build-meta.env；
#     前置：先运行 ./build-common.sh 生成 target）
#
# 产物:
#   build/staging/<APP_NAME>_x86_64-<SPK_VERSION>.spk
#
# 关键设计（注释按本脚本职责重新整理）:
#   - 端口: proxy/dsh/container 读 build-config.yaml spk: 段（默认 30800/30801/30802）
#   - start.sh: 由本脚本按 SPK 端口段生成（gen_start_sh，母版 scripts/start.sh.example，
#     端口/appname 占位符全部注入，无硬编码）
#   - 内层 package.tgz: gzip + --hard-dereference（pnpm 硬链展开，DSM 才能解）；
#     软链保留（旧包含软链可装，软链不是问题）
#   - 外层 .spk: 未压缩 tar，无 ./ 前缀（DSM 规范）
#   - 门户 ui/config: start.sh gen-portal 生成（键名与 INFO dsmappname 逐字一致）
#   - 数据目录版本隔离: 安装脚本按内嵌 dsh 版本建 <var>/<version>/，覆盖安装不丢旧数据
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
# build-config.yaml 解析（SPK 段覆盖 defaults：端口 + appname + 品牌元数据）
#   全部字段一律来自配置，脚本内不写死任何可变值（no-hardcode-config）
# ----------------------------------------------------------------------------
eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f) or {}
defaults = cfg.get('defaults') or {}
spk = cfg.get('spk') or {}
for k, v in {**defaults, **spk}.items():
    if v is None:
        continue
    print(f'CFG_{k.upper()}=\"{v}\"')
" 2>/dev/null || true)"
SPK_PROXY_PORT="${CFG_PROXY_PORT:-30800}"
SPK_DSH_PORT="${CFG_DSH_PORT:-30801}"
SPK_CONTAINER_PORT="${CFG_CONTAINER_PORT:-30802}"

# ── 品牌 / 元数据（配置驱动；缺省值仅作最后兜底，正常一律命中配置） ──
CFG_APPNAME="${CFG_APPNAME:-DeepSeekHarness-NAS}"
CFG_BRAND_NAME="${CFG_BRAND_NAME:-$CFG_APPNAME}"
CFG_DISPLAY_NAME="${CFG_DISPLAY_NAME:-DeepSeek Harness}"
CFG_TITLE="${CFG_TITLE:-$CFG_DISPLAY_NAME}"
CFG_DESC="${CFG_DESC:-}"
CFG_DESC_SHORT="${CFG_DESC_SHORT:-$CFG_DISPLAY_NAME Web UI}"
CFG_MAINTAINER="${CFG_MAINTAINER:-DeepSeek AI}"
CFG_MAINTAINER_URL="${CFG_MAINTAINER_URL:-}"
CFG_DISTRIBUTOR="${CFG_DISTRIBUTOR:-}"
CFG_DISTRIBUTOR_URL="${CFG_DISTRIBUTOR_URL:-}"
CFG_OS_MIN_VER="${CFG_OS_MIN_VER:-7.0-40851}"
CFG_BRAND_VERSION_ORDER="${CFG_BRAND_VERSION_ORDER:-dsh,npm}"

# ----------------------------------------------------------------------------
# target 与元数据（build-common.sh 产物）
# ----------------------------------------------------------------------------
_META="$(ls -1t "$D_BUILD"/spk-build/build-*/build-meta.env 2>/dev/null | head -1)"
if [ -z "$_META" ] || [ ! -f "$_META" ]; then
  echo "✗ 未找到 build-meta.env（请先运行 ./build-common.sh 生成 target）" >&2
  exit 1
fi
. "$_META"   # 提供 APP_NAME/APP_ID/PKG_VER/SPK_VERSION/FPK_VERSION/DESC/TARGET/WORK
if [ ! -d "$TARGET" ] || [ ! -f "$TARGET/package.json" ]; then
  echo "✗ target 缺失或不完整: $TARGET（请先运行 ./build-common.sh）" >&2
  exit 1
fi
echo "使用 target : $TARGET（dsh $PKG_VER | SPK $SPK_VERSION | APP_NAME $APP_NAME）"

# 排除规则（build-excludes.json dist 模式）
EXCLUDES_FILE="$SCRIPT_DIR/build-excludes.json"
mapfile -t TAR_EXCLUDES < <(python3 -c "
import json
with open('$EXCLUDES_FILE') as f:
    cfg = json.load(f)
for x in cfg.get('dist', {}).get('excludes', []):
    if not x.startswith('_comment'):
        print(x)
" 2>/dev/null || true)

# ----------------------------------------------------------------------------
# start.sh 生成（SPK 端口段；母版占位符 → 配置值）
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
      -e "s|__PORTAL_DESC__|${CFG_DESC_SHORT}|g" \
      "$D_SCRIPTS/start.sh.example" > "$out"
  chmod +x "$out"
  if grep -qE "__PROXY_PORT__|__DSH_PORT__|__CONTAINER_PORT__|__APP_NAME__|__APP_ID__|__BRAND_NAME__|__BRAND_VERSION_ORDER__|__FPK_VERSION__|__PORTAL_TITLE__|__PORTAL_DESC__" "$out"; then
    echo "[!] start.sh 占位符未全部替换: $out" >&2; exit 1
  fi
}

# 重新生成 start.sh（避免复用 target 时残留旧包名/旧端口）
gen_start_sh "$TARGET/start.sh" "$SPK_PROXY_PORT" "$SPK_DSH_PORT" "$SPK_CONTAINER_PORT"

#===============================================================================
# 一、组装 SPK 外层（assemble）
#===============================================================================
echo ""
echo "══════ SPK 打包（群晖 x86_64）══════"
ASSEMBLE="$WORK/assemble"
rm -rf "$ASSEMBLE"
mkdir -p "$ASSEMBLE"

# DSM 门户 ui/config（target 内；安装后 webman 软链 → webman/3rdparty/<pkg> 指向 target/ui）。
# 键名必须与 INFO dsmappname 逐字一致，否则桌面图标点不开。
# 由 start.sh 自带 gen-portal 生成（端口/appname 同一份构建配置，无静态模板）
"$TARGET/start.sh" gen-portal --type url --key-prefix "SYNO.SDS." --all-users false > "$TARGET/ui/config"

# INFO（版本 = SPK 前三位；desc/displayname/maintainer 等一律来自 build-config.yaml，
#   仅 DESC 在配置留空时回退 build-meta.env 的 README 摘要）
cat > "$ASSEMBLE/INFO" <<EOF
package="${APP_NAME}"
version="${SPK_VERSION}"
description="${CFG_DESC:-$DESC}"
arch="x86_64"
maintainer="${CFG_MAINTAINER}${CFG_DISTRIBUTOR:+ / $CFG_DISTRIBUTOR}"
maintainer_url="${CFG_MAINTAINER_URL}"
distributor="${CFG_DISTRIBUTOR}"
distributor_url="${CFG_DISTRIBUTOR_URL}"
os_min_ver="${CFG_OS_MIN_VER}"
reloadui="yes"
displayname="${CFG_DISPLAY_NAME} NAS"
dsmuidir="ui"
dsmappname="SYNO.SDS.${APP_ID}.Application"
checksum=""
changelog="[独立包名 ${APP_NAME}] dsh ${PKG_VER} 全源码编译; 品牌 ${CFG_BRAND_NAME}; 版本号自动取官方前三位"
EOF

# conf: privilege（应用用户名按 APP_NAME 替换）+ resource（脚本管理时必须 {}，
#   DSM 7 postinst worker 无法为 port-config/data-share 建系统资源 → 276 失败）
mkdir -p "$ASSEMBLE/conf"
sed "s/deepseek-harness-nas/${APP_NAME}/g" "$D_ASSETS/conf/privilege" > "$ASSEMBLE/conf/privilege"
printf '{}' > "$ASSEMBLE/conf/resource"

# scripts/installer：生命周期钩子（包名取运行期 $SYNOPKG_PKGNAME，零硬编码）
mkdir -p "$ASSEMBLE/scripts"
cat > "$ASSEMBLE/scripts/installer" <<'INSTALLER_EOF'
#!/bin/sh
PACKAGE_NAME="$SYNOPKG_PKGNAME"
PACKAGE_BASE="/var/packages/${PACKAGE_NAME}/target"
PACKAGE_SSS="/var/packages/${PACKAGE_NAME}/scripts/start-stop-status"
PKG_VAR_DIR="/var/packages/${PACKAGE_NAME}/var"

# 读取打包内嵌版本号（数据目录按版本隔离：<var>/<version>/）
# 来源优先级与 bin/start.sh 的 resolve_pkg_version 一致（dsh 包 → npm 产物 → 顶层），
# 顺序来自 build-config.yaml brand_version_order（打包期替换 __BRAND_VERSION_ORDER_COMMA__）
pkg_version() {
  local src="$1" f v
  case "$src" in
    dsh)
      for f in "${PACKAGE_BASE}/node_modules/@deepseek-ai/dsh/package.json" \
               "${PACKAGE_BASE}/node_modules/node_modules/@deepseek-ai/dsh/package.json" \
               "${PACKAGE_BASE}/apps/cli/package.json"; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)"
        [ -n "$v" ] && { echo "$v"; return 0; }
      done ;;
    npm)
      for f in "${PACKAGE_BASE}/node_modules/@deepseek-ai/dsh-client-ui-sidebar/lib/client.js" \
               "${PACKAGE_BASE}/node_modules/node_modules/@deepseek-ai/dsh-client-ui-sidebar/lib/client.js"; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/.*function localBuildVersion()[^{]*{[[:space:]]*return[[:space:]]*`\([^`]*\)`.*/\1/p' "$f" 2>/dev/null | head -1)"
        [ -n "$v" ] && { echo "$v"; return 0; }
      done ;;
    top)
      f="${PACKAGE_BASE}/package.json"
      [ -f "$f" ] && sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1 ;;
  esac
  return 0
}
pkg_version_resolved() {
  local s v
  for s in __BRAND_VERSION_ORDER_COMMA__ top; do
    v="$(pkg_version "$s")"
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  echo "__FPK_VERSION__"
}

# 安装后初始化：版本隔离数据目录 + 权限修复 + dsh 命令软链
setup_pkg_env() {
  local VER="$(pkg_version_resolved)"
  mkdir -p "${PKG_VAR_DIR}/${VER}"
  chown -R "${PACKAGE_NAME}:system" "${PKG_VAR_DIR}/${VER}" 2>/dev/null || true
  fix_ownership
  link_dsh_cmd
}

fix_ownership() {
  chown -R "${PACKAGE_NAME}:system" "${PACKAGE_BASE}" 2>/dev/null || true
  chown -R "${PACKAGE_NAME}:system" "${PACKAGE_BASE}/var" 2>/dev/null || true
  chown -R "${PACKAGE_NAME}:system" "${PKG_VAR_DIR}" 2>/dev/null || true
}

link_dsh_cmd() {
  mkdir -p /usr/local/bin
  ln -sfn "${PACKAGE_BASE}/bin/dsh" /usr/local/bin/dsh 2>/dev/null || true
}

preinst() { exit 0; }

postinst() {
  setup_pkg_env
  exit 0
}

prereplace() {
  setup_pkg_env
  exit 0
}

postreplace() {
  setup_pkg_env
  exit 0
}

# 卸载清理（群晖 CLI 卸载只执行 preuninst；postuninst 双保险）
cleanup_uninstall() {
  local VER="$(pkg_version_resolved)"
  if [ -n "$VER" ] && [ -d "${PKG_VAR_DIR}/${VER}" ]; then
    rm -rf "${PKG_VAR_DIR}/${VER}" 2>/dev/null
  fi
  if [ -d "${PKG_VAR_DIR}" ] && [ -z "$(ls -A "${PKG_VAR_DIR}" 2>/dev/null)" ]; then
    rm -rf "${PKG_VAR_DIR}" 2>/dev/null
  fi
  # 注册软链（/usr/syno/etc/packages/<pkg> → /volumeX/@appconf/<pkg>）及其指向目录
  if [ -e "/usr/syno/etc/packages/${PACKAGE_NAME}" ]; then
    local CONF_TARGET
    CONF_TARGET="$(readlink "/usr/syno/etc/packages/${PACKAGE_NAME}" 2>/dev/null)"
    rm -rf "/usr/syno/etc/packages/${PACKAGE_NAME}" 2>/dev/null
    [ -n "$CONF_TARGET" ] && rm -rf "$CONF_TARGET" 2>/dev/null
  fi
  # 应用用户（群晖卸载不删，需显式删）
  /usr/syno/sbin/synouser --del "${PACKAGE_NAME}" >/dev/null 2>&1 \
    || userdel -r "${PACKAGE_NAME}" 2>/dev/null || true
  # dsh 命令软链（若指向本包则清）
  rm -f /usr/bin/dsh /usr/local/bin/dsh 2>/dev/null || true
}

preuninst() {
  "${PACKAGE_SSS}" stop
  cleanup_uninstall
  exit 0
}

postuninst() {
  cleanup_uninstall
  exit 0
}

preupgrade() {
  "${PACKAGE_SSS}" stop
  exit 0
}

postupgrade() {
  setup_pkg_env
  exit 0
}

# hook 分发：DSM 以 `scripts/installer <hook名>` 子命令方式调用
case "$1" in
  preinst)      preinst ;;
  postinst)     postinst ;;
  prereplace)   prereplace ;;
  postreplace)  postreplace ;;
  preuninst)    preuninst ;;
  postuninst)   postuninst ;;
  preupgrade)   preupgrade ;;
  postupgrade)  postupgrade ;;
  *)            exit 0 ;;
esac
INSTALLER_EOF

# start-stop-status：DSM 启停（端口只认 var/ports，由本脚本生成）
cat > "$ASSEMBLE/scripts/start-stop-status" <<'SSS_EOF'
#!/bin/sh
PACKAGE_NAME="${SYNOPKG_PKGNAME}"
PACKAGE_BASE="/var/packages/${PACKAGE_NAME}/target"
START_SCRIPT="${PACKAGE_BASE}/start.sh"

# 端口由 build-spk.sh 依 build-config.yaml 生成的 var/ports 提供（不硬编码）
PORT_FILE="${PACKAGE_BASE}/var/ports"
if [ -f "$PORT_FILE" ]; then
  . "$PORT_FILE"
fi

if [ -z "${PROXY_PORT}" ] || [ -z "${DSH_PORT}" ] || [ -z "${CONTAINER_PORT}" ]; then
  echo "错误：未找到 ${PORT_FILE}（端口应由打包时生成），无法确定服务端口" >&2
  exit 1
fi

running_dsh() {
  netstat -tln 2>/dev/null | grep -q ":${DSH_PORT} " && return 0
  ps -ef 2>/dev/null | grep "start.sh" | grep -v grep | grep -q . && return 0
  return 1
}

stop() {
  "${START_SCRIPT}" stop --proxy-port "$PROXY_PORT" --dsh-port "$DSH_PORT" --container-port "$CONTAINER_PORT" 2>/dev/null || true
  sleep 2
  pkill -f "bin.js web" 2>/dev/null || true
  sleep 1
  pkill -9 -f "start.sh" 2>/dev/null || true
  return 0
}

start() {
  mkdir -p "${PACKAGE_BASE}/var/logs" "${PACKAGE_BASE}/var/data"
  export HOME="${PACKAGE_BASE}"
  export DSH_HOME="${PACKAGE_BASE}/.dsh-home/.dsh"
  "${START_SCRIPT}" start \
    --proxy-port "$PROXY_PORT" \
    --dsh-port "$DSH_PORT" \
    --container-port "$CONTAINER_PORT" \
    > "${PACKAGE_BASE}/var/logs/start.log" 2>&1 &
  sleep 5
  if ! running_dsh; then
    return 1
  fi
  return 0
}

status() {
  if running_dsh; then
    echo "running"
    exit 0
  else
    echo "stopped"
    exit 1
  fi
}

case "$1" in
  start)   start; exit $?;;
  stop)    stop; exit 0;;
  status)  status;;
  log)     echo "${PACKAGE_BASE}/var/logs/start.log"; exit 0;;
esac
SSS_EOF
chmod +x "$ASSEMBLE/scripts/"*
# scripts 内占位符统一替换（品牌版本优先级链 / 版本兜底；不替换 → 装完数据目录名会带占位符）
sed -i "s/__BRAND_VERSION_ORDER_COMMA__/${CFG_BRAND_VERSION_ORDER//,/ }/g; s/__FPK_VERSION__/${FPK_VERSION}/g; s/__APP_NAME__/${APP_NAME}/g" "$ASSEMBLE/scripts/"* 2>/dev/null || true
if grep -rlE "__BRAND_VERSION_ORDER_COMMA__|__FPK_VERSION__|__APP_NAME__" "$ASSEMBLE/scripts/" 2>/dev/null | grep -q .; then
  echo "[!] scripts 占位符未全部替换" >&2; exit 1
fi

# 门户图标 + 外层 ui/config（与 target 同源）
mkdir -p "$ASSEMBLE/ui/images"
cp "$D_ASSETS/ui/images/"*.png "$ASSEMBLE/ui/images/" 2>/dev/null || true
cp "$TARGET/ui/config" "$ASSEMBLE/ui/config"
cp "$D_ASSETS/PACKAGE_ICON.PNG" "$D_ASSETS/PACKAGE_ICON_256.PNG" "$ASSEMBLE/"

# var/ports 落盘（start-stop-status 读取；端口全部 build-config.yaml 驱动）
echo "▶ SPK 端口: $SPK_PROXY_PORT/$SPK_DSH_PORT/$SPK_CONTAINER_PORT"
grep -q "${SPK_PROXY_PORT}" "$TARGET/start.sh" || echo "⚠ start.sh 未含端口 $SPK_PROXY_PORT"
cat > "$TARGET/var/ports" <<PORTS_EOF
# SPK 端口配置（build-config.yaml spk: 段驱动，start-stop-status 读取）
PROXY_PORT=${SPK_PROXY_PORT}
DSH_PORT=${SPK_DSH_PORT}
CONTAINER_PORT=${SPK_CONTAINER_PORT}
PORTS_EOF
echo "  ✓ var/ports 已生成"

# ----------------------------------------------------------------------------
# 二、修正权限 + 打包
# ----------------------------------------------------------------------------
# DSM 要求标准权限（目录755 文件644 脚本755）；工作区 0707 会带进包 → 313/263 错误
find "$TARGET" -type d -exec chmod 755 {} + 2>/dev/null
find "$TARGET" -type f ! -executable -exec chmod 644 {} + 2>/dev/null
find "$TARGET" -type f -executable -exec chmod 755 {} + 2>/dev/null
find "$ASSEMBLE" -type d -exec chmod 755 {} + 2>/dev/null
find "$ASSEMBLE" -type f ! -path '*/scripts/*' -exec chmod 644 {} + 2>/dev/null
chmod 755 "$ASSEMBLE/scripts/"* 2>/dev/null || true
chmod 644 "$ASSEMBLE/INFO" "$ASSEMBLE/conf/privilege" "$ASSEMBLE/conf/resource" \
        "$ASSEMBLE/PACKAGE_ICON.PNG" "$ASSEMBLE/PACKAGE_ICON_256.PNG" \
        "$ASSEMBLE/ui/config" 2>/dev/null || true
chmod 755 "$ASSEMBLE/scripts/start-stop-status" "$ASSEMBLE/scripts/installer" 2>/dev/null || true

# 内层 package.tgz（gzip；--hard-dereference 硬链展开；软链保留——旧包含软链可装）
echo "▶ 打包 package.tgz（gzip, 预构建产物包, ${#TAR_EXCLUDES[@]} 条排除规则）"
tar -czf "$ASSEMBLE/package.tgz" --hard-dereference -C "$TARGET" \
  "${TAR_EXCLUDES[@]}" .
if tar -xOf "$ASSEMBLE/package.tgz" 2>/dev/null | tar -tzf - 2>/dev/null | grep -q '^h'; then
  echo "  ⚠ 仍有硬链接未展开"
fi

# 外层 SPK（未压缩 tar，无 ./ 前缀；组包前再修一次 assemble 权限）
find "$ASSEMBLE" -type d -exec chmod 755 {} + 2>/dev/null
find "$ASSEMBLE" -type f -exec chmod 644 {} + 2>/dev/null
chmod 755 "$ASSEMBLE/scripts/"* 2>/dev/null || true
chmod 755 "$ASSEMBLE/scripts/start-stop-status" "$ASSEMBLE/scripts/installer" 2>/dev/null || true

OUT_SPK="$D_STAGING/${APP_NAME}_x86_64-${SPK_VERSION}.spk"
# ⚠ staging 是 gitignore 的产物目录，CI 全新 checkout 不存在 → tar 因写不进去失败
#   （exit code 2）。本地长期有该目录，掩盖了此问题。
mkdir -p "$D_STAGING"
echo "▶ 组装外层 SPK → $OUT_SPK"
( cd "$ASSEMBLE" && tar -cf "$OUT_SPK" INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG conf scripts ui package.tgz )

sync   # CIFS 元数据滞后，不 sync 时 du 读旧大小
_SPK_SIZE=$(du -m --apparent-size "$OUT_SPK" 2>/dev/null | cut -f1)
echo "  ✅ SPK: $OUT_SPK (${_SPK_SIZE}MB | MD5 $(md5sum "$OUT_SPK" | awk '{print $1}'))"
# 大小门禁：超过 600MB 说明平台裁剪失败或有意外大包
if [ "${_SPK_SIZE:-0}" -gt 600 ]; then
  echo "❌ SPK 体积异常: ${_SPK_SIZE}MB > 600MB 门禁。检查平台裁剪是否生效。" >&2
  exit 1
fi

#===============================================================================
# 三、汇总
#===============================================================================
echo ""
echo "════════════════════════════════════════════════"
echo "✅ SPK 构建完成（产物已放入暂存区，尚未验证）"
echo "  SPK   : $OUT_SPK"
echo "  版本  : 官方 $PKG_VER | SPK $SPK_VERSION"
echo "  端口  : $SPK_PROXY_PORT / $SPK_DSH_PORT / $SPK_CONTAINER_PORT"
echo "────────────────────────────────────────────────"
echo "发布目录 $D_STAGING 只放暂存；实装验证后执行:"
echo "  scripts/promote-release.sh <包文件名>"
echo "════════════════════════════════════════════════"