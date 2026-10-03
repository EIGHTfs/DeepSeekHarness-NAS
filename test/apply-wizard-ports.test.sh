#!/bin/bash
#===============================================================================
# apply-wizard-ports.test.sh — 验证 SPK installer 的端口逻辑（三场景）
#===============================================================================
# 【被测对象】build/SPK/pack-spk.sh 的 installer 母版中 apply_wizard_ports()：
#   最终生效端口 = 向导值 → 历史 ports 文件 → 打包默认；并**无条件**把 ui/config
#   门户端口同步为最终值（2026-10-02 修复：重装未填端口时不再跳过同步）。
#
# 【场景】
#   S1 重装未填向导端口，但历史 ports 文件有 3080/3081/3082 → ui/config 应为 3080
#   S2 全新安装填向导端口 3090/3091/3092 → ui/config 应为 3090
#   S3 全新安装未填端口（无历史）→ ui/config 应为打包默认 30800
#
# 【设计】从 pack-spk.sh 实时提取 installer 母版（改源码即测新逻辑，不复制产物）；
#   mktemp 隔离工作目录，结束清理，零污染。
# 【用法】./test/apply-wizard-ports.test.sh   （退出码 0=全过；非 0=失败）
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SPK="$SCRIPT_DIR/../build/SPK/pack-spk.sh"
[ -f "$BUILD_SPK" ] || { echo "✗ 未找到 pack-spk.sh: $BUILD_SPK" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
INST="$WORK/installer.sh"

# ── 1. 提取 installer 母版（INSTALLER_EOF heredoc + 占位符替换）──────────────
python3 - "$BUILD_SPK" > "$INST" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"cat > \"\$ASSEMBLE/scripts/installer\" <<'INSTALLER_EOF'\n(.*?)\nINSTALLER_EOF", src, re.S)
if not m:
    sys.exit('✗ 未提取到 installer 母版')
inst = m.group(1)
for k, v in [('__SPK_PROXY_PORT__', '30800'), ('__SPK_DSH_PORT__', '30801'),
             ('__SPK_CONTAINER_PORT__', '30802'), ('__BRAND_VERSION_ORDER_COMMA__', 'dsh npm top'),
             ('__FPK_VERSION__', '0.2.0-rc.2'), ('__APP_NAME__', 'DeepSeekHarness-NAS')]:
    inst = inst.replace(k, v)
print(inst, end='')
PYEOF
[ -s "$INST" ] || { echo "✗ installer 提取为空" >&2; exit 1; }

# ── 2. 场景模拟器 ─────────────────────────────────────────────────────────────
# run_scenario <场景名> <期望 ui port> <历史 ports 文件内容(可为空)> <wizard 三个值(可为空)>
run_scenario() {
  local name="$1" expect_ui="$2" hist="$3" wz_proxy="$4" wz_dsh="$5" wz_container="$6"
  local pkgbase="$WORK/$name-pkgbase" spkvar="$WORK/$name-var"
  mkdir -p "$pkgbase/ui" "$spkvar/0.2.0-rc.2"
  echo '{"port": "30800"}' > "$pkgbase/ui/config"
  [ -n "$hist" ] && printf '%s\n' "$hist" > "$spkvar/0.2.0-rc.2/ports"

  (
    . "$INST"
    export PACKAGE_NAME=DeepSeekHarness-NAS PACKAGE_BASE="$pkgbase" PKG_VAR_DIR="$spkvar"
    pkg_version_resolved() { echo 0.2.0-rc.2; }
    [ -n "$wz_proxy" ] && export wizard_proxy_port="$wz_proxy"
    [ -n "$wz_dsh" ] && export wizard_dsh_port="$wz_dsh"
    [ -n "$wz_container" ] && export wizard_container_port="$wz_container"
    apply_wizard_ports
  ) >/dev/null 2>&1

  local got_ui
  got_ui="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$pkgbase/ui/config" 2>/dev/null)"
  if [ "$got_ui" = "$expect_ui" ]; then
    echo "  ✓ $name: ui/config port = $got_ui（期望 $expect_ui）"
  else
    echo "  ✗ $name: ui/config port = ${got_ui:-无}（期望 $expect_ui）" >&2
    return 1
  fi
  # ports 文件也应写入最终值
  local got_pp
  got_pp="$(awk -F= '/^PROXY_PORT=/{print $2}' "$spkvar/0.2.0-rc.2/ports" 2>/dev/null)"
  [ "$got_pp" = "$expect_ui" ] || { echo "  ✗ $name: ports PROXY_PORT=$got_pp（期望 $expect_ui）" >&2; return 1; }
  return 0
}

echo "▶ 提取 installer: $INST（$(wc -l < "$INST") 行）"
echo "▶ 运行场景："
pass=0
run_scenario "S1 重装未填端口+历史3080" "3080" "PROXY_PORT=3080
DSH_PORT=3081
CONTAINER_PORT=3082" "" "" "" && pass=$((pass+1))
run_scenario "S2 全新安装填向导3090" "3090" "" "3090" "3091" "3092" && pass=$((pass+1))
run_scenario "S3 全新安装未填端口" "30800" "" "" "" "" && pass=$((pass+1))

echo "──────────────────────────────"
if [ "$pass" -eq 3 ]; then
  echo "✅ 全部 3 个场景通过"
  exit 0
else
  echo "❌ 通过 $pass/3" >&2
  exit 1
fi
