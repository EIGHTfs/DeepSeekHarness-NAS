#!/usr/bin/env bash
#===============================================================================
# scripts/lib/common.sh — **唯一公共函数库**（build / scripts / web-install 三方共用）
#
# 设计口径（用户 2026-10-04）：
#   「此次一鼓作气把所有能公共的都公共」——审计出的重复实现一律收进本文件，
#   各脚本只允许**调用**，不允许再定义同名副本（由
#   scripts/check-common-functions.sh 在 CI 强制）。
#
# 【使用方式】只 source，不执行：
#     . "$(dirname "$0")/../scripts/lib/common.sh"      # 或按各自相对位置
#     . "$BUILD_ROOT/../scripts/lib/common.sh"
#
# 【硬性约束】
#   1. 本文件 **无副作用**：不 set -e/-u、不 cd、不写文件、不打印任何东西。
#   2. 只依赖 bash + coreutils + /proc；可选依赖（sshpass/curl/tar/python3）
#      一律**运行时探测**，缺失时给出明确报错，绝不静默降级。
#   3. 所有破坏性删除必须走 safe_rm_rf()：强制 --one-file-system 且逐级检测
#      挂载点（2026-10-03 数据丢失事故的直接防线）。
#
# 【哪些【不要】收口（2026-10-04 审计纠错，务必先读）】
#   按"函数名重复"做的审计会**误报**：同名但**作用域不同**的代码不能抽，硬抽会破坏生成物。
#   已确认的误报（保留各自实现，勿动）：
#     · log_msg —— build/FPK/build-fpk.sh 里出现两次，但都在 **heredoc 生成的 fnOS 运行时
#       脚本**内（写 ${LOG_FILE}/${TRIM_PKGVAR} 日志），与构建侧日志**不是一回事**。
#     · load_variables_from_file —— build-fpk.sh:364 是 fnOS 运行时要求的**空桩**，
#       :479 才是打包器自己的实现；二者同名不同作用域。
#     · preinst/postinst/preuninst/postuninst/start/status（DSM 专有）与
#       install_callback/service_*（fnOS 专有）—— 平台专有，保留各自实现。
#     · scripts/migrate-session.sh、fix-login-shell.sh、fetch-release-mt.sh 的领域逻辑。
#     · **打包器里嵌入目标运行时的 rm -rf 也不要收口**（2026-10-04 新增，甄别启发式的假阴性）：
#       例 build/SPK/build-spk.sh 的 preuninst/postuninst 段（与 synouser --del 同段）——
#       它**未用 \${} 转义**（值在构建期烘焙），但命令是在**目标机卸载时执行**，目标机上
#       没有 scripts/lib/common.sh → 换成 safe_rm_rf 会直接坏包。判据：看**变量是否被
#       烘焙**（未转义）+ 是否伴随 synouser/userdel/TRIM_*/PKG_VAR 等运行时语义。
#       已实测安全并收口的只有构建期临时目录类（build-common.sh 5 处、fetch-*、diff-report）。
#
#   → 因此 scripts/check-common-functions.sh（第 7 步守卫）必须**先剔除 heredoc 生成区段**
#     再做"唯一性"判定，否则会误伤上述代码。
#
# 【本文件收口的重复项（原散落位置）】
#   日志/文案 info ok warn miss err die log_msg …… prepare-build-env.sh、
#        fix-login-shell.sh、sync-github-release.sh、web-install/* 等 6+ 处
#   safe_rm_rf / has_mount_under …… web-install/clean-dsm-residue.sh
#   rssh（远程执行：sshpass→密钥→候选路径回退）…… web-install/install-remote-*.sh
#   resolve_node（优先 /usr/bin/node，不可执行则自探测）…… 多处
#   fetch_url / extract_tar / md5_of / b64_encode / json_get / json_set ……
#        fetch-dsh-latest.sh、fetch-release-mt.sh、install-remote-*.sh 等
#   load_build_meta / resolve_pkg_version / check_pkg_size / running_dsh / pkg_*
#        …… build/SPK/build-spk.sh 与 build/FPK/build-fpk.sh 各一份
#   gen_start_sh …… 原 build/build-lib.sh（build-lib.sh 现为薄转发）
#===============================================================================

# 防重复 source
[ -n "${_DSH_COMMON_SH_LOADED:-}" ] && return 0
_DSH_COMMON_SH_LOADED=1

#-------------------------------------------------------------------------------
# 一、日志与文案（全仓库唯一实现）
#   风格沿用既有：info=▶  ok=✓  warn=⚠  miss=✗  err=✗(stderr)  die=err+exit
#   注意：$* 不加引号，保留既有多参拼接行为（调用方自行控制文案）
#-------------------------------------------------------------------------------
info()    { echo "▶ $*"; }
ok()      { echo "  ✓ $*"; }
warn()    { echo "  ⚠ $*" >&2; }
miss()    { echo "  ✗ $*" >&2; }
err()     { echo "✗ $*" >&2; }
die()     { echo "✗ $*" >&2; exit 1; }
# 兼容旧名（build/FPK/build-fpk.sh、scripts/sync-github-release.sh 用过）
log_msg() { echo "$*"; }
# 分节标题（构建日志可读性）
section() { echo; echo "═══ $* ═══"; }

#-------------------------------------------------------------------------------
# 二、挂载点与安全删除（事故防线，全仓库唯一实现）
#   has_mount_under <dir>   目录之下（含自身）是否有挂载点
#   safe_rm_rf <path>...    逐个删除；**含挂载点者跳过并告警**，绝不跨文件系统
#   背景：rm -rf /volume1/@appdata/<PKG> 会递归进入其下挂载点并在**源端**删光数据
#        （2026-10-03 事故）；--one-file-system 只能防跨设备删除，故再加显式检测。
#-------------------------------------------------------------------------------
has_mount_under() {
  local dir="$1" m
  [ -e "$dir" ] || return 1
  dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
  while read -r m; do
    case "$m" in
      "$dir"|"$dir"/*) return 0 ;;
    esac
  done <<EOF
$(awk '{ for (i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"\n") }' /proc/mounts 2>/dev/null | sed 's/\\040/ /g')
EOF
  return 1
}

safe_rm_rf() {
  local d rc=0
  for d in "$@"; do
    [ -e "$d" ] || continue
    if has_mount_under "$d"; then
      warn "跳过删除（其下存在挂载点，防跨挂载点误删）: $d"
      rc=1
      continue
    fi
    rm -rf --one-file-system "$d" || { warn "删除失败: $d"; rc=1; }
  done
  return $rc
}

#-------------------------------------------------------------------------------
# 三、远程执行（唯一实现）
#   优先 sshpass（密码）；否则用密钥；密钥候选路径按序探测。
#   超时由 RSSH_TIMEOUT 控制（默认 120s），在**远端**执行，避免 timeout 不能
#   执行 shell 函数的坑（2026-10-03 踩过）。
#   用法：rssh <host> <user> <password|-> '<remote command>'
#-------------------------------------------------------------------------------
RSSH_TIMEOUT="${RSSH_TIMEOUT:-120}"
SSH_KEY="${SSH_KEY:-}"

_rssh_key() {
  local c
  for c in "$SSH_KEY" \
           "${HOME:-/root}/.ssh/id_ed25519" \
           "${HOME:-/root}/.ssh/id_rsa" \
           "/var/packages/DeepSeekHarness-NAS/home/.ssh/id_ed25519" \
           "/var/packages/DeepSeekHarness-NAS/home/.ssh/id_rsa"; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

rssh() {
  local host="$1" user="$2" pass="$3" cmd="$4"
  [ -n "$host" ] && [ -n "$user" ] && [ -n "$cmd" ] || { err "rssh 参数不足"; return 2; }
  if command -v sshpass >/dev/null 2>&1 && [ -n "$pass" ] && [ "$pass" != "-" ]; then
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      -o BatchMode=no "$user@$host" "timeout $RSSH_TIMEOUT sh -c $(printf '%q' "$cmd")" </dev/null
    return $?
  fi
  local k
  if k="$(_rssh_key)"; then
    ssh -i "$k" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" \
      "timeout $RSSH_TIMEOUT sh -c $(printf '%q' "$cmd")" </dev/null
    return $?
  fi
  err "rssh: 无 sshpass 且未找到可用密钥（试过 SSH_KEY/\$HOME/.ssh/*/包内 home/.ssh/*）"
  return 3
}

# 远端可写临时目录（安装器前置检查复用）
rssh_remote_tmp() {
  rssh "$1" "$2" "$3" 'for d in /tmp /var/tmp /volume1/@tmp; do [ -d "$d" ] && [ -w "$d" ] && { echo "$d"; exit 0; }; done; exit 1'
}

#-------------------------------------------------------------------------------
# 四、工具解析与下载
#-------------------------------------------------------------------------------
# node 解析（用户口径 2026-10-03：优先 /usr/bin/node，不可执行则自探测）
resolve_node() {
  local c
  for c in /usr/bin/node /usr/local/bin/node \
           "${DSH_NODE_DIST:-}"/node-v*/bin/node \
           "$(dirname "${BASH_SOURCE[0]}")"/../../tools/node-dist/node-v*/bin/node; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  c="$(command -v node 2>/dev/null)"
  [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  return 1
}

# 断点续传下载（-C -）+ 重试；用法：fetch_url <url> <out> [retries]
fetch_url() {
  local url="$1" out="$2" tries="${3:-3}" i=0
  command -v curl >/dev/null 2>&1 || { err "fetch_url: 缺少 curl"; return 1; }
  while [ "$i" -lt "$tries" ]; do
    i=$((i+1))
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$out" "$url" && return 0
    warn "下载失败（第 $i/$tries 次）: $url"
    sleep 3
  done
  return 1
}

# 解压 tar（自动识别 .gz/.xz/.zst，zst 需 zstd）
extract_tar() {
  local f="$1" dest="$2"
  mkdir -p "$dest" || return 1
  case "$f" in
    *.tar.gz|*.tgz) tar -xzf "$f" -C "$dest" ;;
    *.tar.xz)       tar -xJf "$f" -C "$dest" ;;
    *.tar.zst)      command -v zstd >/dev/null 2>&1 || { err "extract_tar: 缺少 zstd"; return 1; }
                    zstd -dc "$f" | tar -xf - -C "$dest" ;;
    *.tar)          tar -xf "$f" -C "$dest" ;;
    *) err "extract_tar: 未知格式 $f"; return 1 ;;
  esac
}

md5_of()   { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
b64_encode() { base64 | tr -d '\n'; }
b64_decode() { base64 -d; }

# JSON 读写（python3 唯一实现，收敛散落的 python3 -c）
json_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1],encoding="utf-8"));
import functools
k=sys.argv[2].split(".")
v=functools.reduce(lambda o,x:o.get(x) if isinstance(o,dict) else None, k, d)
print("" if v is None else v)' "$1" "$2" 2>/dev/null; }

json_set() { python3 - "$1" "$2" "$3" <<'PY'
import json,sys
p,path,val=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(p,encoding="utf-8"))
o=d; ks=path.split(".")
for k in ks[:-1]: o=o.setdefault(k,{})
o[ks[-1]]=val
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
}

#-------------------------------------------------------------------------------
# 五、构建元数据 / 版本 / 体积门禁 / 进程 / 套件操作（打包器共用）
#-------------------------------------------------------------------------------
# 读取 build-meta.env（由 build-common.sh 生成），导出 APP_NAME/APP_ID/
# PKG_VER/SPK_VERSION/FPK_VERSION/DESC/TARGET/WORK
# 用法：load_build_meta <build-meta.env 路径>
load_build_meta() {
  local meta="$1"
  [ -f "$meta" ] || { err "load_build_meta: 找不到 $meta"; return 1; }
  # shellcheck disable=SC1090
  . "$meta"
  return 0
}

# 包版本解析：DSM(dsh/npm 顺序) 与 fnOS 口径不同 → 用参数区分，避免互相污染
# 用法：resolve_pkg_version <order:dsh,npm> <dsh_ver> <npm_ver>
resolve_pkg_version() {
  local order="$1" dsh="$2" npm="$3" k
  IFS=',' read -r -a _ord <<< "$order"
  for k in "${_ord[@]}"; do
    case "$k" in
      dsh) [ -n "$dsh" ] && { echo "$dsh"; return 0; } ;;
      npm) [ -n "$npm" ] && { echo "$npm"; return 0; } ;;
    esac
  done
  echo ""
}

# 体积门禁（默认 600MB；用户口径）
check_pkg_size() {
  local f="$1" limit_mb="${2:-600}" sz
  [ -f "$f" ] || { err "check_pkg_size: 找不到 $f"; return 1; }
  sz=$(du -m "$f" 2>/dev/null | awk '{print $1}')
  if [ "${sz:-0}" -ge "$limit_mb" ]; then
    err "包体积超门禁: ${sz}MB ≥ ${limit_mb}MB ($f)"
    return 1
  fi
  ok "体积门禁通过: ${sz}MB < ${limit_mb}MB"
}

# DSH 是否在跑（SPK/FPK 共用，**唯一实现**）
#    = DSH 端口（必传：SPK 用 SPK_DSH_PORT，FPK 用 FPK_DSH_PORT）
#    = 本应用 start.sh 的**绝对路径**（可选，用于进程兜底）
#   ⚠ 禁止宽松的 ps -ef | grep start.sh：会命中命令行含 start.sh 的无关进程
#     （含诊断命令自身），实测导致 status 恒判「运行中」→ 系统不再拉起服务
#     （2026-09-13 教训，原 FPK 实现注释）。故只认：端口在听，或绝对路径精确匹配。
running_dsh() {
  local port="$1" startsh="$2"
  if [ -n "$port" ]; then
    if command -v netstat >/dev/null 2>&1; then
      netstat -tln 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v ss >/dev/null 2>&1; then
      ss -tln 2>/dev/null | grep -q ":${port} " && return 0
    fi
  fi
  if [ -n "$startsh" ] && command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$(printf %s "$startsh" | sed "s/\./\\./g")" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# 套件操作封装（DSM；fnOS 侧如需可自行包一层，不硬套）
pkg_status()    { /usr/syno/bin/synopkg status "$1" 2>/dev/null; }
pkg_is_running(){ pkg_status "$1" | grep -q '"status":"running"'; }
pkg_start()     { /usr/syno/bin/synopkg start "$1" 2>&1; }
pkg_stop()      { /usr/syno/bin/synopkg stop "$1" 2>&1; }
pkg_uninstall() { /usr/syno/bin/synopkg uninstall "$1" 2>&1; }

#-------------------------------------------------------------------------------
# 六、start.sh 生成（母版占位符 → 配置值；SPK/FPK 共用，原 build/build-lib.sh）
#   母版：$BUILD_ROOT/start.sh.example（所有可变值一律来自 build-config.yaml）
#   $1 输出路径  $2 proxy 端口  $3 dsh 端口  $4 容器端口  $5 portal_desc
#   ⚠ 第 5 参（门户描述）**必传**：SPK 与 FPK 兜底口径不同，由调用方决定。
#-------------------------------------------------------------------------------
gen_start_sh() {
  local out="$1" proxy="$2" dsh="$3" cont="$4"
  local desc="${5?gen_start_sh: 第 5 参 portal_desc 必传（口径由调用方决定）}"
  [ -f "${BUILD_ROOT:?gen_start_sh: 需先定义 BUILD_ROOT}/start.sh.example" ] || {
    err "gen_start_sh: 找不到母版 $BUILD_ROOT/start.sh.example"; return 1; }
  sed -e "s|__PROXY_PORT__|${proxy}|g" \
      -e "s|__DSH_PORT__|${dsh}|g" \
      -e "s|__CONTAINER_PORT__|${cont}|g" \
      -e "s|__APP_NAME__|${APP_NAME}|g" \
      -e "s|__APP_ID__|${APP_ID}|g" \
      -e "s|__BRAND_NAME__|${CFG_BRAND_NAME}|g" \
      -e "s|__BRAND_VERSION_ORDER__|${CFG_BRAND_VERSION_ORDER}|g" \
      -e "s|__FPK_VERSION__|${FPK_VERSION}|g" \
      -e "s|__PORTAL_TITLE__|${CFG_TITLE}|g" \
      -e "s|__PORTAL_DESC__|${desc}|g" \
      "$BUILD_ROOT/start.sh.example" > "$out"
  chmod +x "$out"
  if grep -qE "__PROXY_PORT__|__DSH_PORT__|__CONTAINER_PORT__|__APP_NAME__|__APP_ID__|__BRAND_NAME__|__BRAND_VERSION_ORDER__|__FPK_VERSION__|__PORTAL_TITLE__|__PORTAL_DESC__" "$out"; then
    err "start.sh 占位符未全部替换: $out"; return 1
  fi
  return 0
}
