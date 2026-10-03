#!/bin/bash
# ============================================================
#  DeepSeekHarness-NAS 远程套件工具（飞牛 fnOS 专用）
#  群晖有独立脚本 install-remote-spk.sh（本脚本只做 fnOS）
#  子命令（就近集中，一个脚本管安装/卸载/检查）:
#    install   <包文件> [主机] [用户名]        # 参数1为 .fpk 即视为 install
#    uninstall          [主机] [用户名]        # 停止+卸载+清残留
#    check              [主机] [用户名]        # 状态+端口+dsh软链+残留
#  系统固定 fnos；端口一律读 build-config.yaml 的 fpk 段（权威配置，禁止写死）
#  ⚠ fnOS 生命周期钩子以应用用户（非 root）执行（2026-09-13 实测 uid=964），
#     install_callback 无法写 /usr/local/bin → dsh/pnpm 软链必须由本脚本以 root 补建
#  缺省主机/用户名读 install-config.json（AI 助手维护，明文密码仅本机）
#  安装流程: 探远端临时目录(真实卷) → 上传(base64) → 解码+MD5校验
#        → appcenter-cli install-fpk → root 补建软链 → start → 验证
#  验证: 端口段(fpk 段) + token 门户 302 + 版本隔离目录 + dsh 软链
# ===========================================================
set -u
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 2026-09-15 归位：install-config.json 与脚本同目录（web-install/）
CFG="$WS/install-config.json"
# --- 读取配置（密码不输出） ---
read_cfg() {
  local key="$1"
  python3 - "$key" "$CFG" <<'PYEOF'
import json, sys
key, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path, encoding='utf-8'))
    print(d.get(key, ''))
except Exception:
    print('')
PYEOF
}

# --- 读取 build-config.yaml 的 fpk 端口段（权威配置，禁止写死） ---
#   只读 fpk 段：专属字段 > defaults 通用字段（fpk 留空自然回落 3080 段）
#   输出: "PROXY DSH CONTAINER" 空格分隔；配置缺失/解析失败输出空串
read_ports() {
  python3 - "$WS" <<'PYEOF'
import sys, os
script_dir = sys.argv[1]
base = script_dir
cands = [os.path.join(base, '..', 'build', 'build-config.yaml'),
         os.path.join(base, '..', 'build-config.yaml'),
         os.path.join(base, 'build-config.yaml')]
try:
    import yaml
except ImportError:
    sys.exit(0)
for cand in cands:
    if os.path.exists(cand):
        try:
            cfg = yaml.safe_load(open(cand, encoding='utf-8'))
            d = cfg.get('defaults', {}) or {}
            sec = cfg.get('fpk') or {}
            proxy = sec.get('proxy_port') or d.get('proxy_port') or ''
            dsh = sec.get('dsh_port') or d.get('dsh_port') or ''
            cont = sec.get('container_port') or d.get('container_port') or ''
            if proxy and dsh and cont:
                print('%s %s %s' % (proxy, dsh, cont))
        except Exception:
            pass
        break
PYEOF
}

# --- 远端系统确认（必为 fnOS，防误装） ---
detect_remote() {
  local host="$1" user="$2" pass="$3" port="${4:-22}"
  timeout 25 sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$host" -p "$port" \
    "for p in /usr/trim /usr/local/bin/appcenter-cli /usr/local/bin/fnpack; do [ -e \"\$p\" ] && echo Y:\$p; done" 2>/dev/null \
    | grep -c '^Y:/usr/trim' || true
}

# --- 参数解析（兼容旧用法：参数1为 .fpk 文件即视为 install） ---
CMD="${1:-usage}"
SPK=""
HOST=""; USER=""; PASS=""; SYSTEM="fnos"
APP_NAME="$(read_cfg appname)"; [ -n "$APP_NAME" ] || APP_NAME="DeepSeekHarness-NAS"
HOST="$(read_cfg host)"
USER="$(read_cfg user)"; [ -n "$USER" ] || USER="root"
PASS="$(read_cfg password)"
R_PORT="$(read_cfg ssh_port)"; [ -n "$R_PORT" ] || R_PORT="22"
ARG_IDX=0
for arg in "$@"; do
  ARG_IDX=$((ARG_IDX + 1))
  case "$arg" in
    install|uninstall|check|usage) CMD="$arg" ;;
    *.fpk) SPK="$arg" ;;
    *)
      # 位置参数：1=主机 2=用户名 3=密码（兼容 .fpk 在其后的旧式传法）
      if [ -z "$HOST" ]; then HOST="$arg"
      elif [ -z "$USER" ]; then USER="$arg"
      elif [ -z "$PASS" ]; then PASS="$arg"
      fi
      ;;
  esac
done
# 参数 1 若为 .fpk 文件且未显式给命令 → 视为 install
if [ -n "$SPK" ] && [ "$CMD" = "usage" ]; then CMD="install"; fi

if [ "$CMD" = "usage" ] || [ -z "$HOST" ]; then
  echo "用法: $0 install <包.fpk> [主机] [用户名] [密码]"
  echo "      $0 uninstall [主机] [用户名] [密码]"
  echo "      $0 check     [主机] [用户名] [密码]"
  echo "系统固定 fnos；主机/用户名/密码缺省读 install-config.json"
  exit 0
fi

read -r PROXY_PORT DSH_PORT CONTAINER_PORT <<< "$(read_ports)"
if [ -z "$PROXY_PORT" ]; then
  echo "✗ 未从 build-config.yaml 读到 fpk 端口段（检查 fpk.proxy_port/dsh_port/container_port）" >&2
  exit 1
fi
APP_LABEL="$APP_NAME（飞牛 fnOS）"

echo "▶ 目标: $USER@$HOST  ▶ 子命令: $CMD  ▶ 系统: fnos  ▶ 端口: ${PROXY_PORT}/${DSH_PORT}/${CONTAINER_PORT}"

# ── 远程卸载（fnOS：appcenter-cli，卸载前先 stop） ─────────────
do_uninstall() {
  echo "▶ 停止并卸载 $APP_LABEL ..."
  timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
    "echo '$PASS' | sudo -S bash -c 'appcenter-cli stop $APP_NAME >/dev/null 2>&1; appcenter-cli uninstall $APP_NAME 2>&1 | tail -1'" 2>&1 \
    | grep -v "chdir" | head -2
  echo ""
  echo "完成。"
}

# ── 远程检查（fnOS：状态/端口/dsh 软链/残留） ────────────────
do_check() {
  echo "▶ 检查 $APP_LABEL @ $HOST ..."
  timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  appcenter状态: \"; appcenter-cli status $APP_NAME 2>/dev/null | head -2 | tr -d \"\n\"; echo
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  数据目录: \"; ls -d /vol*/@appdata/$APP_NAME 2>/dev/null | head -1 || echo \"未找到\"
echo -n \"  应用目录: \"; ls -d /var/apps/$APP_NAME 2>/dev/null || echo \"未找到\"
echo -n \"  dsh命令: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  pnpm命令: \"; ls /usr/bin/pnpm 2>/dev/null || echo \"无\"
echo -n \"  残留-应用目录: \"; ls -d /var/apps/$APP_NAME 2>/dev/null || echo \"✓已清\"
'" 2>&1 | grep -v "chdir"
  echo ""
  echo "完成。"
}

# ── 分发：uninstall / check 直接执行并退出 ──
if [ "$CMD" = "uninstall" ]; then
  do_uninstall; exit $?
fi
if [ "$CMD" = "check" ]; then
  do_check; exit $?
fi

# ── install 流程 ──
[ -f "$SPK" ] || { echo "✗ fpk 不存在: $SPK"; exit 1; }
echo "▶ 包:   $SPK ($(du -h "$SPK" | cut -f1))"

# 0) 远端临时目录：真实卷优先（/tmp 会受限）
echo "▶ 探测远端临时目录 ..."
REMOTE_TMPDIR=""
for cand in "${R_TMP:-}" /vol2/@tmp/dsh-install /vol1/@tmp/dsh-install /tmp/dsh-install; do
  [ -n "$cand" ] || continue
  if timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
     "echo '$PASS' | sudo -S bash -c 'mkdir -p $cand && chmod 777 $cand && touch $cand/.w && rm -f $cand/.w'" >/dev/null 2>&1; then
    REMOTE_TMPDIR="$cand"; break
  fi
done
[ -n "$REMOTE_TMPDIR" ] || { echo "✗ 远端无可写临时目录"; exit 1; }
SPK_BYTES=$(stat -c%s "$SPK" 2>/dev/null || echo 0)
NEED_KB=$(( SPK_BYTES * 22 / 10 / 1024 ))
AVAIL_KB=$(timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "df -k $REMOTE_TMPDIR 2>/dev/null | tail -1 | awk '{print \$4}'" 2>/dev/null | tr -d '\r')
echo "  临时目录: $REMOTE_TMPDIR (可用 ${AVAIL_KB:-?} KB, 需要 ≥${NEED_KB} KB)"
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  echo "✗ 远端临时目录空间不足：需 ${NEED_KB}KB，仅 ${AVAIL_KB}KB"; exit 1
fi
timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "rm -f /tmp/*.b64 /tmp/*.spk /tmp/*.fpk 2>/dev/null; true" >/dev/null 2>&1

# 1) 上传（base64 管道）
echo "▶ 上传 fpk ..."
B64_TMP="$REMOTE_TMPDIR/${SPK##*/}.b64"
if ! base64 -w0 "$SPK" | timeout 1800 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" "cat > $B64_TMP && echo OK" 2>&1 | grep -v chdir | grep -q OK; then
  echo "✗ 上传失败"; exit 1
fi
B64_EXPECT=$(( (SPK_BYTES + 2) / 3 * 4 ))
B64_ACTUAL=$(timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "stat -c%s $B64_TMP 2>/dev/null" 2>/dev/null | tr -d '\r')
if [ -n "$B64_ACTUAL" ] && [ "$B64_ACTUAL" != "$B64_EXPECT" ]; then
  echo "✗ 上传不完整：远端 $B64_ACTUAL 字节，应为 $B64_EXPECT 字节"; exit 1
fi
echo "  ✓ 上传完成 ($SPK_BYTES 字节)"

# 2) 远端解码（sudo）+ MD5 校验
echo "▶ 解码 ..."
REMOTE_SPK="$REMOTE_TMPDIR/${SPK##*/}"
REMOTE_DECODE_PY="import base64; d=base64.b64decode(open('$B64_TMP','rb').read()); open('$REMOTE_SPK','wb').write(d); print('decoded', len(d))"
if ! timeout 1800 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
     "echo '$PASS' | sudo -S bash -c \"python3 -c \\\"$REMOTE_DECODE_PY\\\"; chmod 644 $REMOTE_SPK; rm -f $B64_TMP\"" \
     2>&1 | grep -v "chdir" | grep -q decoded; then
  echo "✗ 解码失败"; exit 1
fi
echo "  ✓ 解码完成"
LOCAL_MD5=$(md5sum "$SPK" | awk '{print $1}')
REMOTE_MD5=$(timeout 300 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "md5sum $REMOTE_SPK 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r')
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
  echo "✗ MD5 不一致：本地 $LOCAL_MD5 / 远端 ${REMOTE_MD5:-空} —— 传输损坏，中止安装"; exit 1
fi
echo "  ✓ MD5 一致 ($LOCAL_MD5)"

# 3) 安装（fnOS：appcenter-cli install-fpk；装前先停+卸载防残留）
echo "▶ 安装 ..."
timeout 300 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "echo '$PASS' | sudo -S bash -c 'appcenter-cli stop $APP_NAME >/dev/null 2>&1; appcenter-cli uninstall $APP_NAME >/dev/null 2>&1; appcenter-cli install-fpk $REMOTE_SPK 2>&1 | tail -1'" 2>&1 \
  | grep -v "chdir" | head -2

# 3') root 补建 dsh/pnpm 软链（fnOS 钩子以应用用户跑，写不了系统 PATH）
echo "▶ 补建 dsh/pnpm 软链（root）..."
timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
APP_DIR=\$(readlink -f /var/apps/${APP_NAME}/target 2>/dev/null || echo /vol1/@appcenter/${APP_NAME})
echo \"  应用体: \$APP_DIR\"
for _n in dsh pnpm; do
  if [ -f \"\$APP_DIR/bin/\$_n\" ]; then
    ln -sf \"\$APP_DIR/bin/\$_n\" /usr/bin/\$_n 2>/dev/null && echo \"  [软链] /usr/bin/\$_n → \$APP_DIR/bin/\$_n\"
  fi
done
'" 2>&1 | grep -v chdir | head -6

# 4) 启动（fnOS）
echo "▶ 启动 ..."
timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" \
  "echo '$PASS' | sudo -S appcenter-cli start $APP_NAME 2>&1 | tail -1" 2>&1 | grep -v "chdir" | head -2
sleep 4

# 5) 验证（fnOS：appcenter 状态 + 端口段 + 数据/应用目录 + dsh 软链）
echo "▶ 验证 ..."
PKG="$APP_NAME"
timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -p "$R_PORT" "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  appcenter状态: \"; appcenter-cli status ${PKG} 2>/dev/null | head -2 | tr -d \"\n\"; echo
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  数据目录: \"; ls -d /vol*/@appdata/${PKG} 2>/dev/null | head -1 || echo \"未找到\"
echo -n \"  应用目录: \"; ls -d /var/apps/${PKG} 2>/dev/null || echo \"未找到\"
echo -n \"  dsh命令: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  pnpm命令: \"; ls /usr/bin/pnpm 2>/dev/null || echo \"无\"
'" 2>&1 | grep -v "chdir"
echo "▶ token 门户:"
timeout 10 curl -s -o /dev/null -w "  http://$HOST:${PROXY_PORT}/ → HTTP %{http_code} → %{redirect_url}\n" "http://$HOST:${PROXY_PORT}/" 2>&1 | head -1
echo ""
echo "完成。"