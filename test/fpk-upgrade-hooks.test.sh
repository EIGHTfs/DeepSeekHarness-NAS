#!/bin/bash
# FPK 升级钩子回归测试
#
# 为什么需要：
#   fnOS 升级时执行的是 upgrade_init / upgrade_callback，不走 install_callback。
#   而打包期为了让 fnOS 解压不报 acl_get_file failed，app.tgz 里刻意不含任何软链，
#   软链只在回调里按 links.tar 还原 —— 一旦升级钩子退化成空壳，升级后内置插件会全部
#   failed to import，且包本身看起来完全正常。
#
# 本测试直接检查「生成物」而不是外层打包脚本的注释，避免注释写得对、代码已走样。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/fpk/pack-fpk.sh"
PASS=0
FAIL=0

chk_ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
chk_bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "═══ FPK 升级钩子测试 ═══"

# 抽出『cmd/package』那一整段 heredoc 内容（它才是装到机器上执行的东西）
GEN="$(python3 - "$SRC" <<'PY'
import io, sys
lines = io.open(sys.argv[1], encoding='utf-8').read().split('\n')
start = None
for i, line in enumerate(lines):
    if 'cat > "$FPK_SRC/cmd/package"' in line:
        start = i
        break
if start is None:
    print('')
    raise SystemExit(0)
end = None
for j in range(start + 1, len(lines)):
    if lines[j].strip() == 'SHELL':
        end = j
        break
print('\n'.join(lines[start + 1:end]) if end else '')
PY
)"

if [ -z "$GEN" ]; then
  chk_bad "未能从 pack-fpk.sh 抽出 cmd/package 生成段"
  echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
  exit 1
fi
chk_ok "已抽出 cmd/package 生成段（$(printf '%s' "$GEN" | wc -l | tr -d ' ') 行）"

# ① 六个钩子都存在
for fn in install_init install_callback uninstall_callback upgrade_init upgrade_callback; do
  printf '%s' "$GEN" | grep -q "^${fn}()" && chk_ok "钩子 ${fn} 已定义" || chk_bad "钩子 ${fn} 缺失"
done

# ② 装配后处理被抽成共享函数，且安装/升级都调用它（不允许两份实现）
printf '%s' "$GEN" | grep -q '^_ensure_payload_env()' \
  && chk_ok "共享装配函数 _ensure_payload_env 已定义" || chk_bad "共享装配函数缺失"

for fn in install_callback upgrade_callback; do
  body="$(printf '%s' "$GEN" | awk "/^${fn}\\(\\)/,/^}/")"
  printf '%s' "$body" | grep -q '_ensure_payload_env' \
    && chk_ok "${fn} 调用了共享装配（软链会被还原）" || chk_bad "${fn} 未调用共享装配 → 升级后软链不会还原"
done

# ③ 升级钩子不能是空壳
printf '%s' "$GEN" | grep -q 'upgrade_init() { exit 0; }' \
  && chk_bad "upgrade_init 仍是空壳" || chk_ok "upgrade_init 不是空壳"
printf '%s' "$GEN" | grep -q 'upgrade_callback() { exit 0; }' \
  && chk_bad "upgrade_callback 仍是空壳" || chk_ok "upgrade_callback 不是空壳"

# ④ 端口跨升级保留：升级前备份、升级后回填
init_body="$(printf '%s' "$GEN" | awk '/^upgrade_init\(\)/,/^}/')"
cb_body="$(printf '%s' "$GEN" | awk '/^upgrade_callback\(\)/,/^}/')"
printf '%s' "$init_body" | grep -q 'ports.pre-upgrade' \
  && chk_ok "upgrade_init 备份端口设置" || chk_bad "upgrade_init 未备份端口设置"
printf '%s' "$cb_body" | grep -q 'ports.pre-upgrade' \
  && chk_ok "upgrade_callback 回填端口设置" || chk_bad "upgrade_callback 未回填端口设置"

# ⑤ 生成物整体语法必须过
GEN_FILE="$(mktemp /tmp/fpk-gen-XXXXXX.sh)"
{ echo '#!/bin/bash'; printf '%s\n' "$GEN"; } > "$GEN_FILE"
if bash -n "$GEN_FILE" 2>/dev/null; then chk_ok "生成物语法通过"; else chk_bad "生成物语法不通过"; fi
rm -f "$GEN_FILE"

echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ]
