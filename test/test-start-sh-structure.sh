#!/bin/bash
# 启动脚本分区纪律的纯结构测试：不启动服务、不依赖真实实例。
# 覆盖：四要素齐全、source 不执行 main、self-check 正常与异常退出码。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/pkgsrc/start.sh.example"
PASS=0; FAIL=0
chk_ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
chk_bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "═══ 启动脚本分区纪律测试 ═══"
# ① 四要素存在
grep -q '^resolve_environment() {' "$SRC" && chk_ok "resolve_environment 已定义" || chk_bad "resolve_environment 缺失"
grep -qF 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then' "$SRC" && chk_ok "source 保护存在" || chk_bad "source 保护缺失"
grep -q '^cmd_self_check() {' "$SRC" && chk_ok "cmd_self_check 已定义" || chk_bad "cmd_self_check 缺失"
grep -q 'self-check) cmd_self_check ;;' "$SRC" && chk_ok "self-check 已进 main 分发" || chk_bad "self-check 未进 main"
# ② 无重复函数定义
DUP=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$SRC" | sed 's/().*//' | sort | uniq -d)
[ -z "$DUP" ] && chk_ok "无重复函数定义" || chk_bad "重复定义: $DUP"
# ③ 语法
bash -n "$SRC" && chk_ok "bash -n 通过" || chk_bad "bash -n 失败"
# ④ 占位符数量不减（注入链安全）
for p in __PROXY_PORT__ __DSH_PORT__ __CONTAINER_PORT__ __APP_NAME__ __FPK_VERSION__; do
  grep -q "$p" "$SRC" && chk_ok "占位符 $p 保留" || chk_bad "占位符 $p 丢失"
done
# ⑤ source 时不执行 main：若执行了 main，会打印用法或因参数校验非零中止
out=$(bash -c 'source "$1" 2>/dev/null; echo SOURCED_OK' _ "$SRC" 2>&1)
printf '%s' "$out" | grep -q 'SOURCED_OK' && chk_ok "source 后可继续执行（未提前退出）" || chk_bad "source 途中退出"
printf '%s' "$out" | grep -q '用法:' && chk_bad "source 触发了 main 的用法输出" || chk_ok "source 未触发 main"
# ⑥ source 后函数可用
bash -c 'source "$1" 2>/dev/null; declare -F resolve_environment >/dev/null && declare -F cmd_self_check >/dev/null' _ "$SRC" \
  && chk_ok "source 后解析/自检函数可用" || chk_bad "source 后函数不可用"

# ⑦ 插件兼容性体检（升级后最容易静默坏的地方：插件抢注全局钩子 / 被宿主禁用）
grep -q '⑦ 插件兼容性' "$SRC" && chk_ok "自检含插件兼容性项" || chk_bad "自检缺插件兼容性项"
grep -q "disabling profile plugin" "$SRC" && chk_ok "体检覆盖「被宿主禁用的插件」" || chk_bad "体检未覆盖插件禁用"
grep -q '__DSH_FILE_UPLOAD__\[\[:space:\]\]\*=' "$SRC" \
  && chk_ok "体检覆盖「抢注上传钩子」" || chk_bad "体检未覆盖上传钩子抢注"

# ⑧ 升级场景：必须能清理「PID 文件里没有但占着端口」的残留实例
grep -q 'kill_stale_instances()' "$SRC" && chk_ok "存在残留实例清理函数" || chk_bad "缺残留实例清理函数"
grep -q '已清理 $_stale' "$SRC" && chk_ok "stop 会清理残留并如实报告" || chk_bad "stop 未处理残留实例"
if grep -E 'pgrep|pkill' "$SRC" | grep -vE '^[[:space:]]*#' | grep -q .; then
  chk_bad "代码里仍依赖 pgrep/pkill（DSM 无这些命令）"
else
  chk_ok "代码不依赖 pgrep/pkill（仅在注释里说明）"
fi

# ⑨ PID 文件必须跨版本稳定（放在 var 根，而非 var/<版本>/）
grep -q 'PID_DIR="${DSH_PKG_VAR_ROOT' "$SRC" \
  && chk_ok "PID 目录取 var 根（跨版本稳定）" || chk_bad "PID 目录仍随版本变化"
grep -q 'DSH_PKG_VAR_ROOT' "$SRC" && chk_ok "定义 var 根变量" || chk_bad "缺 var 根变量"

# ⑩ 依赖兜底必须同时认 package 与 module（原生二进制缺失报的是 MODULE）
grep -q 'Cannot find (package|module)' "$SRC" \
  && chk_ok "依赖缺失检测覆盖 package 与 module" || chk_bad "只认 package，会漏掉原生包缺失"
grep -q 'rescue_deps' "$SRC" && chk_ok "存在在线补包兜底" || chk_bad "缺在线补包兜底"
grep -q 'DEP_RESCUE_REGISTRY' "$SRC" && chk_ok "补包 registry 可配" || chk_bad "补包 registry 未定义"
# 过滤路径型缺失（只保留裸包名，避免把 /abs/path 或 ./rel 当包名去装）
grep -qF "grep -vE '^(\\.|/|[A-Za-z]:)'" "$SRC" && chk_ok "过滤路径型缺失" || chk_bad "未过滤路径型缺失"

# ⑪ 可选功能包补齐：必须后台静默（不阻塞启动、不催用户重启），且不重复补
#    数据源是 .deps-pending（启动清空日志前摘出来的包名）——日志会被 ensure_tmpfile_writable 清空，
#    所以不能直接从日志读。
grep -q 'rescue_deps $_pending' "$SRC" && chk_ok "存在后台补包" || chk_bad "缺后台补包"
grep -q 'deps-pending' "$SRC" && chk_ok "补包数据源是 .deps-pending" || chk_bad "缺 .deps-pending"
grep -q 'ensure_tmpfile_writable "\$LOG_FILE"' "$SRC" && chk_ok "日志清空点仍在（摘记录须在其之前）" || chk_bad "日志清空点异常"
python3 - "$SRC" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
harvest = src.find('.deps-pending')
clear = src.find('ensure_tmpfile_writable "$LOG_FILE"')
print('  ✓ 摘记录在清空日志之前' if 0 < harvest < clear else '  ✗ 摘记录不在清空之前（记录会丢）')
PYEOF
grep -q 'deps-need-restart' "$SRC" && chk_bad "仍有「催重启」标记（应静默）" || chk_ok "补包对用户无感（无催重启提示）"
grep -q '启动前预检' "$SRC" && chk_bad "仍有阻塞式启动前预检" || chk_ok "启动不等待补包"

echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ]
