#!/bin/bash
# ============================================================
#  群晖 DSM 套件卸载残留清理
#
#  背景：`synopkg uninstall` 只删 /var/packages 与 @appstore，
#        会遗留以下几类残留，导致下次安装报
#        263 "failed to create temp dir" / "failed to locate given package"：
#          - 孤儿系统用户/组（home 目录已删但用户还在 → 安装器建临时目录失败）
#          - /volume*/@appconf/<pkg> 空目录
#          - systemd unit（pkgctl-<pkg>.service / <pkg>.slice）
#          - /var/cache/synopkg/installed/existence 里的"已安装"标记
#          - DSM UI 目录 /usr/syno/synoman/webman/3rdparty/<pkg>
#
#  用法：
#    scripts/clean-dsm-residue.sh <套件名> [目标主机] [SSH用户]
#  例：
#    scripts/clean-dsm-residue.sh DeepSeekHarness-NAS 192.168.1.100 admin
#
#  密码来源（按顺序）：环境变量 DSM_PASS > 工作区 install-config.json
#  远端执行方式：base64 传脚本再解码执行（避开多层引号/heredoc 嵌套）
# ============================================================
set -uo pipefail

PKG="${1:-}"
HOST="${2:-}"
USER_SSH="${3:-}"

[ -n "$PKG" ] || { echo "用法: $0 <套件名> [主机] [SSH用户]" >&2; exit 1; }

WS="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$WS/install-config.json"

if [ -f "$CFG" ]; then
  eval "$(python3 - "$CFG" <<'PY' 2>/dev/null || true
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    raise SystemExit
print('CFG_PASS="%s"' % (d.get('password') or d.get('passwd') or ''))
print('CFG_HOST="%s"' % (d.get('host') or d.get('nas_host') or ''))
print('CFG_USER="%s"' % (d.get('user') or d.get('username') or d.get('account') or ''))
PY
)"
  [ -z "$HOST" ] && HOST="${CFG_HOST:-}"
  [ -z "$USER_SSH" ] && USER_SSH="${CFG_USER:-}"
fi
[ -n "$HOST" ] || { echo "✗ 未指定主机，且 install-config.json 无 host" >&2; exit 1; }
[ -n "$USER_SSH" ] || USER_SSH="admin"

PASS="${DSM_PASS:-${CFG_PASS:-}}"
[ -n "$PASS" ] || { echo "✗ 未找到密码（env DSM_PASS 或 install-config.json）" >&2; exit 1; }

echo "▶ 目标: $USER_SSH@$HOST   套件: $PKG"

REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
PKG="$1"
echo "-- 1. 停止套件与进程 --"
/usr/syno/bin/synopkg stop "$PKG" >/dev/null 2>&1
/usr/syno/bin/synopkg uninstall "$PKG" >/dev/null 2>&1
pkill -f "/@appstore/$PKG" 2>/dev/null
pkill -f "target/bin/node.*$PKG" 2>/dev/null
sleep 2

echo "-- 2. 删除目录 --"
rm -rf "/var/packages/$PKG" "/usr/syno/etc/packages/$PKG"
for v in /volume1 /volume2 /volume3 /volume4; do
  rm -rf "$v/@appstore/$PKG" "$v/@appconf/$PKG" "$v/@appdata/$PKG" \
         "$v/@apphome/$PKG" "$v/@apptemp/$PKG" "$v/@appshare/$PKG" \
         "$v/@eaDir/$PKG" "$v/$PKG"
done
rm -rf "/usr/syno/synoman/webman/3rdparty/$PKG"

echo "-- 3. 删除 systemd unit + 日志 + 锁 --"
rm -f "/usr/local/lib/systemd/system/pkgctl-$PKG.service"
rm -f "/etc/systemd/system/syno-low-priority-packages.target.wants/pkgctl-$PKG.service"
rm -f "/usr/syno/etc/synosystemd/enable-status-changed/pkgctl-$PKG.service"
rm -f "/usr/syno/etc/synosystemd/pkgctl-$PKG.service"
rm -f "/usr/local/lib/systemd/system/$(echo "$PKG" | tr '-' '_').slice"
rm -f "/var/log/systemd/pkgctl-$PKG.service.log"
rm -f "/var/log/systemd/pkgctl-$(echo "$PKG" | tr 'A-Z' 'a-z').service.log"
rm -f "/var/log/packages/$PKG.log"
rm -f "/var/log/packages/$(echo "$PKG" | tr 'A-Z' 'a-z').log"
rm -f "/run/synopkg/lock/$PKG.lock"
rm -f "/run/lock/sharesnap/sharesnap_snapcount_lock/$PKG.lock"
systemctl daemon-reload >/dev/null 2>&1
systemctl reset-failed >/dev/null 2>&1

echo "-- 4. 删除孤儿用户/组（263 failed to create temp dir 的主因）--"
/usr/syno/sbin/synouser --del "$PKG" >/dev/null 2>&1
/usr/syno/sbin/synogroup --del "$PKG" >/dev/null 2>&1
/usr/syno/sbin/synogroup --del "$(echo "$PKG" | tr 'A-Z' 'a-z')" >/dev/null 2>&1
if grep -q "^$PKG:" /etc/passwd 2>/dev/null; then
  cp /etc/passwd "/etc/passwd.bak.$(date +%s)" && sed -i "/^$PKG:/d" /etc/passwd \
    && echo "  （已从 /etc/passwd 直接移除 $PKG）"
fi
if grep -q "^$PKG:" /etc/group 2>/dev/null; then
  cp /etc/group "/etc/group.bak.$(date +%s)" && sed -i "/^$PKG:/d" /etc/group \
    && echo "  （已从 /etc/group 直接移除 $PKG）"
fi

echo "-- 5. 清理 synopkg 已装缓存标记 + DSM UI 缓存 --"
python3 -c "
import json, sys, os
pkg = sys.argv[1]
for f in ('/var/cache/synopkg/installed/existence',
          '/var/cache/synopkg/installed/existence.bak',
          '/var/cache/synopkg/installed/ui_config_sketch',
          '/var/cache/synopkg/installed/ui_config_sketch.bak'):
    if not os.path.exists(f):
        print('  （无 ' + f + '）'); continue
    try:
        d = json.load(open(f, encoding='utf-8'))
    except Exception:
        print('  （解析失败跳过: ' + f + '）'); continue
    if isinstance(d, dict) and pkg in d:
        del d[pkg]
        json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False)
        print('  cache 已移除键: ' + f)
    else:
        print('  cache 无该键: ' + f)
" "$PKG" 2>/dev/null
# DSM UI 配置缓存（js_config_parser 缓存含包名条目）
rm -f /var/cache/js_config_parser/config/DSM.json 2>/dev/null

echo "-- 6. 清理 samba/共享配置残留 --"
for f in /usr/syno/etc/sharesnap/sharesnap.conf /usr/syno/etc/share_right.map; do
  if [ -f "$f" ] && grep -q "$PKG" "$f" 2>/dev/null; then
    cp "$f" "$f.bak.$(date +%s)" && sed -i "/$PKG/d" "$f" \
      && echo "  已清理: $f"
  fi
done

echo "-- 7. 核查 --"
left=0
for p in "/var/packages/$PKG" "/volume1/@appstore/$PKG" "/volume2/@appstore/$PKG" \
         "/volume1/@appconf/$PKG" "/volume2/@appconf/$PKG" \
         "/volume1/@appdata/$PKG" "/volume2/@appdata/$PKG" \
         "/volume1/@apphome/$PKG" "/volume2/@apphome/$PKG" \
         "/volume1/@eaDir/$PKG" "/volume2/@eaDir/$PKG" \
         "/usr/syno/synoman/webman/3rdparty/$PKG"; do
  [ -e "$p" ] && { echo "  ⚠ 仍在: $p"; left=1; }
done
grep -q "^$PKG:" /etc/passwd 2>/dev/null && { echo "  ⚠ 用户仍在: $PKG"; left=1; }
if [ "$left" = "0" ]; then echo "  ✅ 无残留"; else echo "  ⚠ 有残留（见上）"; fi
REMOTE_EOF
)

B64="$(printf '%s' "$REMOTE_SCRIPT" | base64 -w0)"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
  "$USER_SSH@$HOST" \
  "echo '$PASS' | sudo -S -p '' bash -c \"echo '$B64' | base64 -d | bash -s -- '$PKG'\"" \
  2>&1 | grep -v 'chdir'
