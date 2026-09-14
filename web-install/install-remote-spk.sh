#!/bin/bash
# ============================================================
#  DeepSeekHarness-NAS 远程套件工具（群晖 DSM / 飞牛 fnOS 双分支）
#  子命令（就近集中，一个脚本管安装/卸载/检查）:
#    install   <包文件> [主机] [用户名] [system]  # 参数1为 .spk/.fpk 即视为 install
#    uninstall          [主机] [用户名] [system]  # 停止+卸载+深度清残留
#    check              [主机] [用户名] [system]  # 状态+端口+门户3文件+dsh软链+残留
#  system ∈ dsm|fnos（缺省读 install-config.json 的 system，再缺省按包后缀推断）
#  ⚠ 端口一律读 build-config.yaml（权威配置），禁止写死：
#      dsm → spk 段 proxy_port/dsh_port/container_port（默认 30800/30801/30802）
#      fnos → fpk 段 proxy_port/dsh_port/container_port（默认 3080/3081/3082）
#  缺省主机/用户名读 install-config.json（AI 助手维护，明文密码仅本机）
#  安装流程: 探远端临时目录(真实卷,非tmpfs) → 上传(base64) → 解码+MD5校验
#        → dsm: synopkg install；fnos: appcenter-cli install-fpk → start → 验证
#  注意: DSM 的 /tmp 是 1.5G tmpfs，大包(>200M)会撑爆 → 解码静默截断。
#        故临时目录优先落真实卷（环境变量 R_TMP 可强制指定）
#  验证: 端口段(按分支读配置) + token门户302 + 版本隔离目录 + 门户3文件
#        （门户判定见 ai-work-archive skill: syno-spk-package-guide 1.7.1-F）
# ===========================================================
set -u
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 工作区根 = 脚本目录的上一级（脚本在 scripts/ 里，配置文件在工作区根）
WS_ROOT="$(cd "$WS/.." && pwd)"
CFG="$WS_ROOT/install-config.json"
[ -f "$CFG" ] || CFG="$WS/install-config.json"
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

# --- 读取 build-config.yaml 端口段（权威配置，禁止写死） ---
#   ★ 设计层次（与 build-config.yaml 注释一一对应，改这里必须同步那边）:
#     ① 通用 defaults = 默认端口段（3080/3081/3082），SPK 与 FPK 共用
#     ② spk 段 = 只覆盖端口成 30800/30801/30802，其他配置复用通用
#     ③ fpk 段 = 留空则完全沿用通用（即 3080 段）
#   ★ system → section 映射（两者名字不同，必须转换，否则读错段）:
#     system=dsm  → 读 YAML 'spk' 段（30800 段）
#     system=fnos → 读 YAML 'fpk' 段（缺省回退 defaults → 3080 段）
#   ★ 输出: "PROXY DSH CONTAINER" 空格分隔；配置缺失/解析失败输出空串
read_ports() {
  local sys="$1" secname=""
  # system 名 → YAML section 名（dsm→spk, fnos→fpk；其余为空=只读通用）
  [ "$sys" = "dsm" ] && secname="spk"
  [ "$sys" = "fnos" ] && secname="fpk"
  # 传真实脚本目录（stdin 执行时 __file__=<stdin> 不可靠，abspath 会基于 cwd 解析）
  python3 - "$secname" "$WS" <<'PYEOF'
import sys, os
secname, script_dir = sys.argv[1], sys.argv[2]
base = script_dir
# 候选路径：权威在 build/（打包脚本同级）；旧根副本兜底（2026-09-12 迁移）
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
            d = cfg.get('defaults', {}) or {}          # 通用默认段
            sec = (cfg.get(secname) or {}) if secname else {}  # 专属段（fpk 可能为 None）
            # 读取优先级：专属段字段 > 通用默认字段（fpk 留空自然回落通用）
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

# --- 远端系统探测（sshpass） → 输出 dsm|fnos|unknown|error ---
#   特征文件: 群晖=/etc.defaults/VERSION + /usr/syno/bin/synopkg
#             飞牛=/usr/trim + /usr/local/bin/appcenter-cli + /usr/local/bin/fnpack
detect_remote() {
  local host="$1" user="$2" pass="$3" port="${4:-22}"
  timeout 25 sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    -p "$port" "$user@$host" \
    "for p in /etc.defaults/VERSION /usr/syno/bin/synopkg /usr/trim /usr/local/bin/appcenter-cli /usr/local/bin/fnpack; do [ -e \"\$p\" ] && echo Y:\$p; done" 2>/dev/null \
    | grep '^Y:' | awk -F: '{print $2}' | sort > /tmp/dsh-detect-$$.txt
  local dsm=0 fnos=0 p
  while read -r p; do
    case "$p" in
      /etc.defaults/VERSION|/usr/syno/bin/synopkg) dsm=1 ;;
      /usr/trim|/usr/local/bin/appcenter-cli|/usr/local/bin/fnpack) fnos=1 ;;
    esac
  done < /tmp/dsh-detect-$$.txt
  rm -f /tmp/dsh-detect-$$.txt
  if [ "$dsm" = "1" ]; then echo "dsm"; return 0; fi
  if [ "$fnos" = "1" ]; then echo "fnos"; return 0; fi
  echo "unknown"
}

# --- 参数解析（兼容旧用法：参数1为 .spk 文件即视为 install） ---
DEFAULT_SPK="$WS/release/DeepSeekHarness-x86_64-0.1.5.spk"
DEFAULT_APP="$(read_cfg appname)"
[ -n "$DEFAULT_APP" ] || DEFAULT_APP="DeepSeekHarness-NAS"
CMD="install"; SPK="$DEFAULT_SPK"
case "${1:-}" in
  uninstall|check)
    CMD="$1"
    HOST="${2:-$(read_cfg host)}"
    USER="${3:-$(read_cfg username)}"
    APP_NAME="${4:-$DEFAULT_APP}"
    SYSTEM="${5:-}"
    ;;
  install)
    CMD="install"
    SPK="${2:-$DEFAULT_SPK}"
    HOST="${3:-$(read_cfg host)}"
    USER="${4:-$(read_cfg username)}"
    APP_NAME="${5:-$DEFAULT_APP}"
    SYSTEM="${6:-}"
    ;;
  *.spk|*.fpk)
    CMD="install"
    SPK="$1"
    HOST="${2:-$(read_cfg host)}"
    USER="${3:-$(read_cfg username)}"
    APP_NAME="${4:-$DEFAULT_APP}"
    SYSTEM="${5:-}"
    ;;
  *)
    echo "✗ 未知子命令: ${1:-} （可用 install|uninstall|check，或直接传 .spk/.fpk 文件）"; exit 1 ;;
esac
PASS="$(read_cfg password)"
[ -z "$HOST" ] && { echo "✗ 未指定主机（参数或 install-config.json）"; exit 1; }
[ -z "$PASS" ] && { echo "✗ 未找到密码（install-config.json）"; exit 1; }

# --- 系统类型（双分支核心）: 参数 > install-config.json 的 system > 包后缀推断 > dsm ---
#   端口段随分支从 build-config.yaml 读（权威配置，禁止写死）
if [ -z "$SYSTEM" ]; then
  SYSTEM="$(read_cfg system)"
fi
if [ -z "$SYSTEM" ]; then
  case "$SPK" in
    *.fpk) SYSTEM="fnos" ;;
    *)     SYSTEM="dsm" ;;
  esac
fi
if [ "$SYSTEM" != "dsm" ] && [ "$SYSTEM" != "fnos" ]; then
  echo "✗ 未知系统: $SYSTEM （应为 dsm|fnos，可从参数/install-config.json 的 system/包后缀推断）" >&2
  exit 1
fi
read -r PROXY_PORT DSH_PORT CONTAINER_PORT <<< "$(read_ports "$SYSTEM")"
if [ -z "$PROXY_PORT" ]; then
  echo "✗ 未从 build-config.yaml 读到 $SYSTEM 端口段（检查 build-config.yaml 的 $SYSTEM.proxy_port/dsh_port/container_port）" >&2
  exit 1
fi
APP_LABEL="$APP_NAME"
[ "$SYSTEM" = "fnos" ] && APP_LABEL="$APP_NAME（飞牛 fnOS）"

echo "▶ 目标: $USER@$HOST  ▶ 子命令: $CMD  ▶ 系统: $SYSTEM  ▶ 端口: ${PROXY_PORT}/${DSH_PORT}/${CONTAINER_PORT}"

# ── 远程卸载（双分支） ────────────────────────────────────────────
do_uninstall() {
  echo "▶ 停止并卸载 $APP_LABEL ..."
  if [ "$SYSTEM" = "fnos" ]; then
    # 飞牛 fnOS：appcenter-cli（卸载前先 stop，忽略 stop 失败继续 uninstall）
    timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
      "echo '$PASS' | sudo -S bash -c 'appcenter-cli stop $APP_NAME >/dev/null 2>&1; appcenter-cli uninstall $APP_NAME 2>&1 | tail -1'" 2>&1 \
      | grep -v "chdir" | head -2
  else
    # 群晖 DSM：synopkg stop + uninstall + 深度清残留
    timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
      "echo '$PASS' | sudo -S bash -c '/usr/syno/bin/synopkg stop $APP_NAME >/dev/null 2>&1; /usr/syno/bin/synopkg uninstall $APP_NAME 2>&1 | tail -1'" 2>&1 \
      | grep -v "chdir" | head -2
    echo "▶ 深度清理残留（clean-dsm-residue.sh）..."
    DSM_PASS="$PASS" bash "$WS/scripts/clean-dsm-residue.sh" "$APP_NAME" "$HOST" "$USER" 2>&1 | tail -3
  fi
  echo ""
  echo "完成。"
}

# ── 远程检查（双分支：状态/端口/门户/dsh/残留） ─────────────────────
do_check() {
  echo "▶ 检查 $APP_LABEL @ $HOST ..."
  if [ "$SYSTEM" = "fnos" ]; then
    # ── 飞牛 fnOS 分支 ──
    #   状态走 appcenter-cli；端口段来自 build-config.yaml（$PROXY_PORT 等，不写死）；
    #   数据/应用目录用通配卷（/vol*）找，不写死 /vol1——不同应用装不同卷
    #   （见 fnos-fpk-package-guide：安装卷无权限就换卷，别死磕固定路径）
    timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  appcenter状态: \"; appcenter-cli status $APP_NAME 2>/dev/null | head -2 | tr -d \"\n\"; echo
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  数据目录: \"; ls -d /vol*/@appdata/$APP_NAME 2>/dev/null | head -1 || echo \"未找到\"
echo -n \"  应用目录: \"; ls -d /var/apps/$APP_NAME 2>/dev/null || echo \"未找到\"
echo -n \"  dsh命令: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  残留-应用目录: \"; ls -d /var/apps/$APP_NAME 2>/dev/null || echo \"✓已清\"
'" 2>&1 | grep -v "chdir"
  else
    # ── 群晖 DSM 分支 ──
    #   synopkg 状态 + 端口段 + 版本目录 + 残留（sudo 权限项）；门户3文件无 sudo 直读
    timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  synopkg状态: \"; /usr/syno/bin/synopkg status $APP_NAME 2>/dev/null | grep -o \"status[^,]*\" | head -1
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  版本隔离目录: \"; ls /var/packages/$APP_NAME/var/ 2>/dev/null | head -2 | tr -d \"\n\"; echo
echo -n \"  dsh软链: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  残留-包目录: \"; ls -d /var/packages/$APP_NAME 2>/dev/null || echo \"✓已清\"
echo -n \"  残留-应用用户: \"; id $APP_NAME >/dev/null 2>&1 && echo \"⚠存在\" || echo \"✓已清\"
'" 2>&1 | grep -v "chdir"
    # ── 门户3文件判定（dsm 专用；config/Icon/INFO 与 webman 软链对运行用户可读，无需 sudo）──
    #   门户判定规则见 syno-spk-package-guide 1.7.1-F：
    #   ① INFO 含 dsmuidir=ui + dsmappname + reloadui=yes
    #   ② ui/config 的 .url 键名 与 INFO dsmappname 逐字一致
    #   ③ ui/images/icon_{0}.png 存在
    #   用 ssh 单引号参数原样送远端（仅 $APP_NAME 本地拼接），避免双引号二次展开变量
    echo "  [门户判定]"
    timeout 30 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
      'D=/var/packages/'"$APP_NAME"'
I="$D/INFO"; C="$D/target/ui/config"
echo -n "    [门户1] webman软链: "
if [ -L /usr/syno/synoman/webman/3rdparty/'"$APP_NAME"' ]; then echo -n "✓ "; readlink /usr/syno/synoman/webman/3rdparty/'"$APP_NAME"'; echo; else echo "✗ 未建"; fi
echo -n "    INFO dsmuidir: "
grep -qE "^dsmuidir=\"ui\"" "$I" 2>/dev/null && echo "✓ ui" || echo "✗ 缺/非ui"
APP_KEY=$(grep -E "^dsmappname=" "$I" 2>/dev/null | cut -d\" -f2)
CFG_KEY=$(python3 -c "import json; d=json.load(open(\"$C\")); ks=list((d.get(\".url\") or {}).keys()); print(ks[0] if ks else \"\")" 2>/dev/null)
echo -n "    [门户2] ui/config键名: "
[ -n "$CFG_KEY" ] && echo "✓ $CFG_KEY" || echo "✗ config缺失/无.url"
echo -n "             INFO dsmappname: "
[ -n "$APP_KEY" ] && echo "✓ $APP_KEY" || echo "✗ 缺"
echo -n "             键名一致: "
if [ -n "$CFG_KEY" ] && [ "$CFG_KEY" = "$APP_KEY" ]; then echo "✓ 一致"; else echo "✗ 不一致"; fi
echo -n "    [门户3] icon_{0}.png: "
ls "$D/target/ui/images"/icon_*.png >/dev/null 2>&1 && echo "✓ 存在" || echo "✗ 缺失"' \
      2>&1 | grep -v chdir
  fi
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
[ -f "$SPK" ] || { echo "✗ spk 不存在: $SPK"; exit 1; }
echo "▶ 包:   $SPK ($(du -h "$SPK" | cut -f1))"

# 0) 远端临时目录：必须是真实卷（DSM 的 /tmp 是 1.5G tmpfs，装大包会撑爆）
#    优先级：环境变量 R_TMP > /volume2/@tmp/dsh-install > /volume1/... > /tmp/dsh-install
echo "▶ 探测远端临时目录 ..."
REMOTE_TMPDIR=""
for cand in "${R_TMP:-}" /volume2/@tmp/dsh-install /volume1/@tmp/dsh-install /tmp/dsh-install; do
  [ -n "$cand" ] || continue
  if timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
     "echo '$PASS' | sudo -S bash -c 'mkdir -p $cand && chmod 777 $cand && touch $cand/.w && rm -f $cand/.w'" >/dev/null 2>&1; then
    REMOTE_TMPDIR="$cand"; break
  fi
done
[ -n "$REMOTE_TMPDIR" ] || { echo "✗ 远端无可写临时目录"; exit 1; }
SPK_BYTES=$(stat -c%s "$SPK" 2>/dev/null || echo 0)
NEED_KB=$(( SPK_BYTES * 22 / 10 / 1024 ))
AVAIL_KB=$(timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "df -k $REMOTE_TMPDIR 2>/dev/null | tail -1 | awk '{print \$4}'" 2>/dev/null | tr -d '\r')
echo "  临时目录: $REMOTE_TMPDIR (可用 ${AVAIL_KB:-?} KB, 需要 ≥${NEED_KB} KB)"
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  echo "✗ 远端临时目录空间不足：需 ${NEED_KB}KB，仅 ${AVAIL_KB}KB"; exit 1
fi
timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "rm -f /tmp/*.b64 /tmp/*.spk /tmp/*.fpk 2>/dev/null; true" >/dev/null 2>&1

# 1) 上传（base64 管道，避免 scp 被拒）
echo "▶ 上传 spk ..."
B64_TMP="$REMOTE_TMPDIR/${SPK##*/}.b64"
if ! base64 -w0 "$SPK" | timeout 1800 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "cat > $B64_TMP && echo OK" 2>&1 | grep -v chdir | grep -q OK; then
  echo "✗ 上传失败"; exit 1
fi
B64_EXPECT=$(( (SPK_BYTES + 2) / 3 * 4 ))
B64_ACTUAL=$(timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "stat -c%s $B64_TMP 2>/dev/null" 2>/dev/null | tr -d '\r')
if [ -n "$B64_ACTUAL" ] && [ "$B64_ACTUAL" != "$B64_EXPECT" ]; then
  echo "✗ 上传不完整：远端 $B64_ACTUAL 字节，应为 $B64_EXPECT 字节"; exit 1
fi
echo "  ✓ 上传完成 ($SPK_BYTES 字节)"

# 2) 远端解码（sudo）+ MD5 校验
echo "▶ 解码 ..."
REMOTE_SPK="$REMOTE_TMPDIR/${SPK##*/}"
REMOTE_DECODE_PY="import base64; d=base64.b64decode(open('$B64_TMP','rb').read()); open('$REMOTE_SPK','wb').write(d); print('decoded', len(d))"
if ! timeout 1800 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
     "echo '$PASS' | sudo -S bash -c \"python3 -c \\\"$REMOTE_DECODE_PY\\\"; chmod 644 $REMOTE_SPK; rm -f $B64_TMP\"" \
     2>&1 | grep -v "chdir" | grep -q decoded; then
  echo "✗ 解码失败"; exit 1
fi
echo "  ✓ 解码完成"
LOCAL_MD5=$(md5sum "$SPK" | awk '{print $1}')
REMOTE_MD5=$(timeout 300 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "md5sum $REMOTE_SPK 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r')
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
  echo "✗ MD5 不一致：本地 $LOCAL_MD5 / 远端 ${REMOTE_MD5:-空} —— 传输损坏，中止安装"; exit 1
fi
echo "  ✓ MD5 一致 ($LOCAL_MD5)"

# 3) 安装（双分支；装前先停+卸载，防 repair 死锁 / 263 / 313）
#    dsm → synopkg install；fnos → appcenter-cli install-fpk（fpk 是二进制应用包，不走 synopkg）
echo "▶ 安装 ..."
if [ "$SYSTEM" = "fnos" ]; then
  timeout 300 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    "echo '$PASS' | sudo -S bash -c 'appcenter-cli stop $APP_NAME >/dev/null 2>&1; appcenter-cli uninstall $APP_NAME >/dev/null 2>&1; appcenter-cli install-fpk $REMOTE_SPK 2>&1 | tail -1'" 2>&1 \
    | grep -v "chdir" | head -2
else
  timeout 300 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
# 装前先停+卸载（防 repair 死锁 / 263 / 313）
/usr/syno/bin/synopkg stop $APP_NAME >/dev/null 2>&1
/usr/syno/bin/synopkg uninstall $APP_NAME >/dev/null 2>&1
rm -rf /var/packages/$APP_NAME /vol*/@appstore/$APP_NAME /vol*/@appconf/$APP_NAME \
       /vol*/@appdata/$APP_NAME /vol*/@apphome/$APP_NAME /vol*/@apptemp/$APP_NAME \
       /vol*/@appshare/$APP_NAME /vol*/@eaDir/$APP_NAME
rm -f /usr/syno/synoman/webman/3rdparty/$APP_NAME
rm -f /usr/syno/etc/synosystemd/enable-status-changed/pkgctl-$APP_NAME.service
rm -f /etc/systemd/system/syno-low-priority-packages.target.wants/pkgctl-$APP_NAME.service
rm -f /run/synopkg/lock/$APP_NAME.lock
# 清 synopkg 缓存（防 repair 误判）
python3 << PYEOF
import json, os
pkg = \"$APP_NAME\"
for f in [\"/var/cache/synopkg/installed/existence\", \"/var/cache/synopkg/installed/existence.bak\", \"/var/cache/synopkg/installed/ui_config_sketch\", \"/var/cache/synopkg/installed/ui_config_sketch.bak\"]:
    if not os.path.exists(f): continue
    try:
        d = json.load(open(f, encoding=\"utf-8\"))
        if isinstance(d, dict) and pkg in d:
            del d[pkg]
            json.dump(d, open(f, \"w\", encoding=\"utf-8\"), ensure_ascii=False)
    except: pass
PYEOF
systemctl daemon-reload >/dev/null 2>&1
# 安装
/usr/syno/bin/synopkg install $REMOTE_SPK 2>&1 | tail -1
# 补建 dsh/pnpm 软链（root 通道）：实测 DSM 7.4.1 安装时不执行 installer hooks
# （systemd-unit 判定 → 不走 scripts/installer 的 postinst/postreplace），
# 软链只能由本脚本 root 补建 + start.sh cmd_start 运行时自愈双保险。
if [ -f /var/packages/${APP_NAME}/target/bin/dsh ]; then
  ln -sf /var/packages/${APP_NAME}/target/bin/dsh /usr/bin/dsh 2>/dev/null && echo "  [软链] dsh软链已补建root" || echo "  [软链] dsh软链补建失败"
else
  echo "  [软链] target/bin/dsh缺失,跳过补建"
fi
if [ -f /var/packages/${APP_NAME}/target/bin/pnpm ]; then
  ln -sf /var/packages/${APP_NAME}/target/bin/pnpm /usr/bin/pnpm 2>/dev/null && echo "  [软链] pnpm软链已补建root" || echo "  [软链] pnpm软链补建失败"
else
  echo "  [软链] target/bin/pnpm缺失,跳过补建"
fi
'" 2>&1 | grep -v "chdir" | python3 -c "
import json, sys
line = sys.stdin.read().strip()
try:
    d = json.loads(line)
    r = d.get('results', [{}])[0]
    print('  install:', '✓' if d.get('success') else '✗', r.get('stage'), r.get('error',{}).get('description',''))
except Exception:
    print('  install: 输出:', line[:120])
"
fi

# 4) 启动（双分支）
echo "▶ 启动 ..."
if [ "$SYSTEM" = "fnos" ]; then
  timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    "echo '$PASS' | sudo -S appcenter-cli start $APP_NAME 2>&1 | tail -1" 2>&1 | grep -v "chdir" | head -2
else
  timeout 120 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S /usr/syno/bin/synopkg start $APP_NAME 2>&1 | tail -1" 2>&1 | grep -v "chdir" | python3 -c "
import json, sys
line = sys.stdin.read().strip()
try:
    d = json.loads(line)
    print('  start:', '✓' if d.get('success') else '✗', d.get('results',[{}])[0].get('status'))
except Exception:
    print('  start: 输出:', line[:120])
"
fi
sleep 4

# 5) 验证（双分支；dsm 门户3文件判定见 syno-spk-package-guide 1.7.1-F）
echo "▶ 验证 ..."
PKG="$APP_NAME"
if [ "$SYSTEM" = "fnos" ]; then
  # ── 飞牛 fnOS：appcenter-cli 状态 + 端口段变量 + 通配卷目录 ──
  timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  appcenter状态: \"; appcenter-cli status ${PKG} 2>/dev/null | head -2 | tr -d \"\n\"; echo
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  数据目录: \"; ls -d /vol*/@appdata/${PKG} 2>/dev/null | head -1 || echo \"未找到\"
echo -n \"  应用目录: \"; ls -d /var/apps/${PKG} 2>/dev/null || echo \"未找到\"
echo -n \"  dsh命令: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  pnpm命令: \"; ls /usr/bin/pnpm 2>/dev/null || echo \"无\"
'" 2>&1 | grep -v "chdir"
else
  # ── 群晖 DSM：synopkg 状态 + 版本目录 + 残留（sudo）──
  timeout 60 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "echo '$PASS' | sudo -S bash -c '
echo -n \"  端口段($PROXY_PORT/$DSH_PORT/$CONTAINER_PORT): \"
netstat -tln 2>/dev/null | grep -cE \":($PROXY_PORT|$DSH_PORT|$CONTAINER_PORT) \" | xargs echo 个监听
echo -n \"  版本隔离目录: \"; ls /var/packages/${PKG}/var/ 2>/dev/null | head -2
echo -n \"  dsh命令: \"; ls /usr/bin/dsh 2>/dev/null || echo \"无\"
echo -n \"  pnpm命令: \"; ls /usr/bin/pnpm 2>/dev/null || echo \"无\"
'" 2>&1 | grep -v "chdir"
  # ── 门户3文件判定（无 sudo 直读；ssh 单引号参数防本地二次展开，与 do_check 同模式）──
  echo "  [门户判定]"
  timeout 30 sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    'D=/var/packages/'"$PKG"'
I="$D/INFO"; C="$D/target/ui/config"
echo -n "    [门户1/3] webman软链: "
if [ -L /usr/syno/synoman/webman/3rdparty/'"$PKG"' ]; then echo -n "✓ "; readlink /usr/syno/synoman/webman/3rdparty/'"$PKG"'; echo; else echo "✗ 未建 → 桌面/套件中心无入口"; fi
echo -n "    INFO dsmuidir: "
grep -qE "^dsmuidir=\"ui\"" "$I" 2>/dev/null && echo "✓ ui" || echo "✗ 缺/非ui"
APP_KEY=$(grep -E "^dsmappname=" "$I" 2>/dev/null | cut -d\" -f2)
CFG_KEY=$(python3 -c "import json; d=json.load(open(\"$C\")); ks=list((d.get(\".url\") or {}).keys()); print(ks[0] if ks else \"\")" 2>/dev/null)
echo -n "    [门户2/3] ui/config键名: "
[ -n "$CFG_KEY" ] && echo "✓ $CFG_KEY" || echo "✗ config缺失/无.url"
echo -n "             INFO dsmappname: "
[ -n "$APP_KEY" ] && echo "✓ $APP_KEY" || echo "✗ 缺 dsmappname"
echo -n "             键名一致: "
if [ -n "$CFG_KEY" ] && [ "$CFG_KEY" = "$APP_KEY" ]; then echo "✓ 一致"; else echo "✗ 不一致"; fi
echo -n "    [门户3/3] 图标icon_{0}.png: "
ls "$D/target/ui/images"/icon_*.png >/dev/null 2>&1 && echo "✓ 存在" || echo "✗ 缺失"' \
      2>&1 | grep -v chdir
fi
echo "▶ token 门户:"
timeout 10 curl -s -o /dev/null -w "  http://$HOST:${PROXY_PORT}/ → HTTP %{http_code} → %{redirect_url}\n" "http://$HOST:${PROXY_PORT}/" 2>&1 | head -1
echo ""
echo "完成。"