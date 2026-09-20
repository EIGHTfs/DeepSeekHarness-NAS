#!/bin/bash
# ============================================================
# fix-login-shell.sh —— 登录 shell 悬空探测与修复
#
# 适用宿主：fnOS / Synology DSM / Docker / systemd-nspawn / 任意最小化发行版
#
# ── 要解决的问题 ─────────────────────────────────────────────
# NAS / 容器类宿主习惯把服务账号（套件包用户、容器用户）的登录 shell
# 记成 /sbin/nologin，但该文件在很多系统里根本没装：
#   /etc/passwd   : DeepSeekHarness-NAS:x:<uid>:...:/sbin/nologin
#   实际文件系统  : /sbin -> usr/sbin，/usr/sbin/nologin 不存在
#
# 凡是「读登录 shell 当默认 shell」的组件都会踩这个坑。DSH 是典型：
#   subprocess-local 的 terminalEnvironment() 用
#       process.env.SHELL || os.userInfo().shell
#   解析侧边栏终端默认 shell；进程里没设 SHELL 时就读 /etc/passwd，
#   拿到悬空路径后 resolveExecutable 抛
#       subprocess-local: command "/sbin/nologin" is not an executable file
#   侧边栏终端整体不可用（连 shell 选择列表 API 也会一起失败）。
#
# 用法（详见 --help）：无参数=只读探测报告；--check 精简输出供巡检/CI；
#   --patch [文件…] 幂等插入 SHELL 兜底；--passwd 改 /etc/passwd（需 root）；
#   --shell PATH 指定回退 shell（默认 /bin/bash）；--dry-run 只打印不写盘。
#
# ── 退出码 ───────────────────────────────────────────────────
#   0  正常，或已修复
#   3  检测到登录 shell 悬空，但未执行修复（可直接接巡检 / CI）
#   1  出错（权限不足、文件不可写、改写后语法校验失败等）
#
# ── 设计要点 ─────────────────────────────────────────────────
# 零依赖：仅 bash + coreutils（awk / grep / mktemp / stat / cat）。
#         fnOS / DSM 上没有 getent，故一律用 id -u + 解析 /etc/passwd。
# 幂等  ：目标文件已含兜底语句则跳过，重复运行不会重复插入。
# 安全  ：改动前备份 <文件>.bak-<时间戳>，不删任何原文件；改写后先过 bash -n
#         校验，不通过就不写；就地 cat 写入（不用 mv）以保住硬链/软链关系。
# 防重  ：目标按 inode 去重——start.sh 与 build/start.sh.example 可能经软链指向
#         同一份文件，不去重会往同一文件插两遍（实测踩过）。
# ============================================================
set -uo pipefail

MODE="probe"                 # probe | check | patch | passwd
DRY_RUN=0
FALLBACK_SHELL="/bin/bash"   # 回退目标 shell，可用 --shell 覆盖
TARGETS=()                   # --patch 显式目标；空则自动探测

# ── 探测结果（探测阶段填充，报告与修复共用）──
MY_UID=""
MY_NAME=""
PASSWD_SHELL=""              # /etc/passwd 第 7 字段
ENV_SHELL=""                 # 已导出、子进程可见的 SHELL（DSH 的 process.env.SHELL 只认这个）
BASH_SHELL_VAR=""            # bash 自己填的 SHELL 变量（可能未导出，子进程看不到）
RESOLVED_SHELL=""            # DSH 实际会拿到的默认 shell
RESOLVED_SOURCE=""           # 该值的来源分支
VERDICT=""                   # ok | dangling | unset

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_ROOT="."

# ---------- 输出 ----------
C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_RESET=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[ERR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
用法:
  fix-login-shell.sh                     探测 + 诊断报告（只读，默认）
  fix-login-shell.sh --check             精简输出，供巡检 / CI 判退出码
  fix-login-shell.sh --patch [文件...]   给 start.sh 幂等插入 SHELL 兜底
  fix-login-shell.sh --passwd            改 /etc/passwd 登录 shell（需 root）
  fix-login-shell.sh --shell /bin/zsh    指定回退 shell（默认 /bin/bash）
  fix-login-shell.sh --dry-run           只打印将做的改动，不写盘
退出码: 0=正常或已修复   3=检测到悬空未修复   1=出错
EOF
}

# ---------- 探测 ----------
# 不依赖 getent / user（fnOS、DSM 都没有）：用 id 拿身份，awk 解析 /etc/passwd。
probe() {
  MY_UID="$(id -u 2>/dev/null)" || { err "无法取得 uid（id 不可用）"; exit 1; }
  MY_NAME="$(id -un 2>/dev/null)" || MY_NAME="${USER:-unknown}"
  PASSWD_SHELL="$(awk -F: -v u="$MY_UID" '$3 == u { print $7; exit }' /etc/passwd 2>/dev/null)"

  # 只认「已导出、子进程可见」的 SHELL。bash 在 SHELL 未设时会从 /etc/passwd 自己填一个
  # $SHELL，但那是非导出的 shell 变量，node 子进程的 process.env.SHELL 仍是 undefined
  # ——按 bash 变量判会把 DSH 的解析来源误报成 process.env.SHELL。export -p 是内建，不起子进程。
  BASH_SHELL_VAR="${SHELL:-}"
  if export -p 2>/dev/null | grep -q '^declare -x SHELL='; then
    ENV_SHELL="$BASH_SHELL_VAR"
  fi

  # 与 DSH 的 terminalEnvironment() 保持同序：SHELL 环境变量优先，其次 passwd。
  if [ -n "$ENV_SHELL" ]; then
    RESOLVED_SHELL="$ENV_SHELL"; RESOLVED_SOURCE="process.env.SHELL"
  elif [ -n "$PASSWD_SHELL" ]; then
    RESOLVED_SHELL="$PASSWD_SHELL"; RESOLVED_SOURCE="os.userInfo().shell（/etc/passwd）"
  else
    RESOLVED_SHELL=""; RESOLVED_SOURCE="SHELL 与 /etc/passwd 均未设置"
  fi

  # 与 DSH 的 resolveExecutable 同一判据：stat().isFile() 通过且 access(X_OK) 通过。
  if [ -z "$RESOLVED_SHELL" ]; then
    VERDICT="unset"
  elif [ -f "$RESOLVED_SHELL" ] && [ -x "$RESOLVED_SHELL" ]; then
    VERDICT="ok"
  else
    VERDICT="dangling"
  fi
}

# ---------- 报告 ----------
report() {
  local bar="────────────────────────────────────────────────────────────"
  dim "════════════════════════════════════════════════════════════════"
  info " fix-login-shell.sh — 登录 shell 探测报告"
  dim "════════════════════════════════════════════════════════════════"
  info " 当前用户        : $MY_NAME (uid $MY_UID)"
  info " SHELL（已导出） : ${ENV_SHELL:-(未导出)}"
  # bash 自填但未导出的 SHELL 单列一行说明，避免误以为它就是 DSH 的输入。
  if [ -n "$BASH_SHELL_VAR" ] && [ -z "$ENV_SHELL" ]; then
    info " SHELL（bash 变量）: $BASH_SHELL_VAR$C_DIM   ← bash 自填、未导出，node 子进程看不到$C_RESET"
  fi
  info " /etc/passwd     : ${PASSWD_SHELL:-(未设置)}"
  dim " $bar"
  info " DSH 解析来源    : $RESOLVED_SOURCE"
  info " DSH 默认 shell  : ${RESOLVED_SHELL:-(空)}"
  case "$VERDICT" in
    ok)
      info " 可执行性        : $C_GREEN✓ 存在且可执行$C_RESET"
      info " 判定            : $C_GREEN正常，无需修复$C_RESET"
      ;;
    unset)
      info " 可执行性        : $C_YELLOW— 无声明值，DSH 会退到 /bin/sh$C_RESET"
      info " 判定            : $C_YELLOW未设置（可接受）$C_RESET"
      ;;
    dangling)
      info " 可执行性        : $C_RED✗ 不存在或不可执行$C_RESET"
      info " 判定            : $C_RED悬空 — 侧边栏终端会报$C_RESET"
      dim "                 subprocess-local: command \"${RESOLVED_SHELL}\" is not an executable file"
      ;;
  esac
  dim " $bar"
  case "$VERDICT" in
    dangling)
      info " 建议修复        : $0 --patch   （宿主层兜底，安全）"
      info "                 $0 --passwd  （改 /etc/passwd，需 root）"
      ;;
    *) info " 无需处理。" ;;
  esac
  dim "════════════════════════════════════════════════════════════════"
}

# ---------- 用 node 复现 DSH 的解析（有 node 才跑，纯佐证）----------
reproduce_dsh() {
  local node_bin="" c
  for c in "$(command -v node 2>/dev/null)" \
           /var/packages/DeepSeekHarness-NAS/target/bin/node \
           "$SCRIPT_ROOT/../tools/node/bin/node"; do
    [ -n "$c" ] && [ -x "$c" ] && { node_bin="$c"; break; }
  done
  [ -n "$node_bin" ] || return 0
  dim ""
  dim " 用 $node_bin 复现 DSH 的解析逻辑（process.env.SHELL || os.userInfo().shell）:"
  "$node_bin" -e '
    const os = require("os"), fs = require("fs");
    const usr = os.userInfo();
    const def = process.env.SHELL || usr.shell || undefined;
    let statRes;
    try { fs.statSync(def); statRes = "EXISTS"; } catch (e) { statRes = "THROWS " + e.code; }
    console.log("    process.env.SHELL     = " + JSON.stringify(process.env.SHELL));
    console.log("    os.userInfo().shell   = " + JSON.stringify(usr.shell));
    console.log("    -> defaultShell       = " + JSON.stringify(def));
    console.log("    stat(" + JSON.stringify(def) + ")   = " + statRes);
  ' 2>/dev/null || dim "    (node 复现失败，可忽略)"
}

# ---------- 修补 start.sh（幂等 + 备份 + 语法校验）----------
# 兜底语句的幂等标记：已存在则整段跳过。
MARKER='[ -x "${SHELL:-}" ]'

do_patch_file() {
  local f="$1" shell="$2"
  [ -f "$f" ] || { warn "$f 不是文件，跳过"; return 0; }

  if grep -qF "$MARKER" "$f"; then
    warn "$f 已含 SHELL 兜底，跳过（幂等）"
    return 0
  fi
  if [ ! -w "$f" ] && [ "$(id -u)" -ne 0 ]; then
    err "$f 不可写（当前非 root），跳过"
    return 1
  fi

  # line 里带字面 ${SHELL:-}，用 \" 与 \${ 转义出字面引号与花括号。
  local line="[ -x \"\${SHELL:-}\" ] || export SHELL=$shell"
  local tmp bak
  tmp="$(mktemp "${TMPDIR:-/tmp}/fix-login-shell.XXXXXX" 2>/dev/null)" \
    || { err "mktemp 失败"; return 1; }
  bak="${f}.bak-$(date +%Y%m%d-%H%M%S)"

  # 插入位置（两趟判定，避免单趟在文件顺序里被首个 export 行抢先）：
  #   ① 有 TMPDIR 段 → 插到该段之后（DSH start.sh 的环境设置区）
  #   ② 否则       → 插到首个 export 行之后
  #   ③ 都没有     → 追加到文件末尾
  # 锚点用 index() 字面匹配，且刻意避开引号字符，绕开 awk -v 传参的转义歧义。
  local at
  at="$(awk 'index($0, "mkdir -p") > 0 && index($0, "TMPDIR") > 0 { print NR; exit }' "$f")"
  if [ -n "$at" ]; then
    awk -v at="$at" -v line="$line" '{ print; if (NR == at) print line }' "$f" > "$tmp"
  elif grep -qE '^export ' "$f"; then
    awk -v line="$line" 'BEGIN{i=0} { print; if (!i && $0 ~ /^export /) { print line; i=1 } }' "$f" > "$tmp"
  else
    awk -v line="$line" '{ print } END { print line }' "$f" > "$tmp"
  fi
  [ -s "$tmp" ] || { err "$f awk 改写失败"; rm -f "$tmp"; return 1; }

  if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] $f 将变成（前 12 行）:"
    awk 'NR <= 12 { print "      " $0 }' "$tmp"
    rm -f "$tmp"
    return 0
  fi

  # 语法校验不通过就不替换，原文件保持原样。
  if ! bash -n "$tmp" 2>/dev/null; then
    err "$f 改写后 bash -n 失败，放弃替换（原文件未动）"
    rm -f "$tmp"
    return 1
  fi
  cp -p "$f" "$bak" || { err "备份 $bak 失败"; rm -f "$tmp"; return 1; }
  # 就地写入而非 mv：mv 会换成新 inode，硬链伙伴会留在旧内容上、软链也会被换掉。
  # tmp 已过 bash -n 校验，非原子窗口的风险可接受（原文件有备份可回滚）。
  cat "$tmp" > "$f" || { err "$f 写入失败"; rm -f "$tmp"; return 1; }
  ok "$f 已插入 SHELL 兜底（备份：$bak）"
}

# ---------- 目标清单：自动探测 + 解析软链 + 按 inode 去重 ----------
# 两步都必须在 mv 替换之前定稿：mv 会换成新 inode，替换后再判就漏掉软链 / 硬链伙伴；
# 更要紧的是 mv 到软链路径会把软链本身换成普通文件（会破坏 target 目录的软链）。
discover_targets() {
  local p
  for p in \
    /var/packages/DeepSeekHarness-NAS/target/start.sh \
    "$SCRIPT_ROOT/../start.sh" \
    "$SCRIPT_ROOT/../build/start.sh.example"; do
    [ -f "$p" ] && printf '%s\n' "$p"
  done
}

build_target_list() {
  local -a src=() resolved=() out=()
  local p r ino seen=" "

  if [ "${#TARGETS[@]}" -gt 0 ]; then
    src=("${TARGETS[@]}")
  else
    while IFS= read -r p; do [ -n "$p" ] && src+=("$p"); done < <(discover_targets)
  fi

  # 解析软链到真实文件；解析失败或不存在的一律丢弃（只处理真实存在的普通文件）。
  for p in "${src[@]}"; do
    r="$(readlink -f "$p" 2>/dev/null)"
    [ -n "$r" ] && [ -f "$r" ] && resolved+=("$r")
  done

  # 按 inode 去重：同一份文件无论被软链 / 硬链引用几次，只处理一次。
  for p in "${resolved[@]}"; do
    ino="$(stat -c %i "$p" 2>/dev/null)" || continue
    case "$seen" in *" $ino "*) continue;; esac
    seen="${seen}${ino} "
    out+=("$p")
  done

  printf '%s\n' "${out[@]}"
}

# ---------- 改 /etc/passwd（需 root + 二次确认）----------
# 安全提示：登录 shell 改成真实 shell 后，该服务账号即可交互式登录，
# 在 NAS 上属安全放宽，仅在明确需要时执行。
do_passwd() {
  local shell="$1" user="$MY_NAME" confirm="FIX-PASSWD-$MY_UID" ans
  if [ "$(id -u)" -ne 0 ]; then
    err "改 /etc/passwd 需要 root 权限（当前 uid $MY_UID）；可用 sudo 运行。"
    exit 1
  fi

  warn "即将执行（改 $user 的登录 shell）："
  info "  usermod -s $shell $user        （usermod 不可用时改走 awk 重写）"
  info "  效果：${PASSWD_SHELL:-(空)}  ->  $shell"
  warn "  影响：该账号从此可交互式登录（NAS 安全放宽，请确认这是你要的）"
  if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] 到此为止，未写盘。"
    exit 0
  fi
  printf "\n输入 %s 确认（其它任意输入=取消）: " "$confirm"
  read -r ans
  [ "$ans" = "$confirm" ] || { warn "已取消。"; exit 1; }

  local bak="/etc/passwd.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p /etc/passwd "$bak" || { err "备份 /etc/passwd 失败"; exit 1; }

  if command -v usermod >/dev/null 2>&1; then
    usermod -s "$shell" "$user" || { err "usermod 失败"; exit 1; }
  else
    local tmp new
    tmp="$(mktemp /etc/passwd.XXXXXX 2>/dev/null)" || { err "mktemp 失败"; exit 1; }
    awk -F: -v u="$MY_UID" -v s="$shell" 'BEGIN{OFS=":"} $3==u {$7=s} {print}' \
      /etc/passwd > "$tmp" || { err "awk 改写失败"; rm -f "$tmp"; exit 1; }
    # 校验：每行必须仍是 7 字段，避免写坏账号库。
    new="$(awk -F: '{print NF}' "$tmp" | sort -u | tr '\n' ' ')"
    [ "$new" = "7 " ] || { err "改写结果字段数异常（$new），放弃"; rm -f "$tmp"; exit 1; }
    cp -p "$tmp" /etc/passwd && chmod 644 /etc/passwd \
      || { err "写入失败"; rm -f "$tmp"; exit 1; }
    rm -f "$tmp"
  fi

  PASSWD_SHELL="$(awk -F: -v u="$MY_UID" '$3 == u { print $7; exit }' /etc/passwd)"
  if [ "$PASSWD_SHELL" = "$shell" ]; then
    ok "/etc/passwd 已更新（备份：$bak）"
  else
    err "写入后校验失败：读回 $PASSWD_SHELL"
    exit 1
  fi
}

# ---------- 主流程 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check" ;;
    --patch)   MODE="patch" ;;
    --passwd)  MODE="passwd" ;;
    --shell)   shift; FALLBACK_SHELL="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        err "未知参数: $1"; usage; exit 1 ;;
    *)
      if [ "$MODE" = "patch" ]; then TARGETS+=("$1")
      else err "多余位置参数: $1"; usage; exit 1; fi ;;
  esac
  shift
done

probe

# 回退 shell 自身先校验：不校验就写进去，等于把一个新的悬空路径固化下来。
if [ -z "$FALLBACK_SHELL" ] || { [ ! -f "$FALLBACK_SHELL" ] || [ ! -x "$FALLBACK_SHELL" ]; }; then
  err "回退 shell 不可用: ${FALLBACK_SHELL:-<空>}（需是存在且可执行的文件）"
  exit 1
fi

case "$MODE" in
  probe)
    report
    reproduce_dsh
    [ "$VERDICT" = "dangling" ] && exit 3
    exit 0
    ;;

  check)
    if [ "$VERDICT" = "dangling" ]; then
      printf 'FAIL login shell dangling: %s (uid %s)\n' "$RESOLVED_SHELL" "$MY_UID"
      exit 3
    fi
    printf 'OK login shell %s (uid %s)\n' "$RESOLVED_SHELL" "$MY_UID"
    exit 0
    ;;

  patch)
    report
    files=()
    while IFS= read -r p; do [ -n "$p" ] && files+=("$p"); done < <(build_target_list)
    if [ "${#files[@]}" -eq 0 ]; then
      warn "没找到可修补的 start.sh，请用 --patch 文件 指定目标。"
      exit 1
    fi
    dim ""
    dim "  目标（已解析软链 + 按 inode 去重）:"
    for p in "${files[@]}"; do dim "    $p"; done
    rc=0
    for p in "${files[@]}"; do do_patch_file "$p" "$FALLBACK_SHELL" || rc=1; done
    if [ "$rc" -eq 0 ] && [ "$VERDICT" = "dangling" ]; then
      dim ""
      warn "已插入兜底，但当前已运行的进程不会自动变；需重启 DSH 才生效。"
    fi
    exit "$rc"
    ;;

  passwd)
    report
    do_passwd "$FALLBACK_SHELL"
    exit 0
    ;;
esac
