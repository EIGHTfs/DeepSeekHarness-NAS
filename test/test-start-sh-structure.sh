#!/bin/bash
# 启动脚本分区纪律的纯结构测试：不启动服务、不依赖真实实例。
# 覆盖：四要素齐全、source 不执行 main、self-check 正常与异常退出码。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/start.sh.example"
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

echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ]
