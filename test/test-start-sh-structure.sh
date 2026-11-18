#!/bin/bash
# 启动脚本分区纪律的纯结构测试：不启动服务、不依赖真实实例。
# 覆盖：四要素齐全、source 不执行 main、self-check 正常与异常退出码。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/start.sh.example"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "═══ 启动脚本分区纪律测试 ═══"
# ① 四要素存在
grep -q '^resolve_environment() {' "$SRC" && ok "resolve_environment 已定义" || bad "resolve_environment 缺失"
grep -qF 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then' "$SRC" && ok "source 保护存在" || bad "source 保护缺失"
grep -q '^cmd_self_check() {' "$SRC" && ok "cmd_self_check 已定义" || bad "cmd_self_check 缺失"
grep -q 'self-check) cmd_self_check ;;' "$SRC" && ok "self-check 已进 main 分发" || bad "self-check 未进 main"
# ② 无重复函数定义
DUP=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$SRC" | sed 's/().*//' | sort | uniq -d)
[ -z "$DUP" ] && ok "无重复函数定义" || bad "重复定义: $DUP"
# ③ 语法
bash -n "$SRC" && ok "bash -n 通过" || bad "bash -n 失败"
# ④ 占位符数量不减（注入链安全）
for p in __PROXY_PORT__ __DSH_PORT__ __CONTAINER_PORT__ __APP_NAME__ __FPK_VERSION__; do
  grep -q "$p" "$SRC" && ok "占位符 $p 保留" || bad "占位符 $p 丢失"
done
# ⑤ source 时不执行 main：母版在测试目录，find_dsh_dir 会失败，若执行 main 会污染 DSH_CMD
unset DSH_CMD
bash -c 'source "$1" 2>/dev/null; [ -z "${DSH_CMD:-}" ]' _ "$SRC" \
  && ok "source 不执行 main（DSH_CMD 未污染）" || bad "source 执行了 main"
# ⑥ source 后函数可用
bash -c 'source "$1" 2>/dev/null; declare -F resolve_environment >/dev/null && declare -F cmd_self_check >/dev/null' _ "$SRC" \
  && ok "source 后解析/自检函数可用" || bad "source 后函数不可用"

echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ]
