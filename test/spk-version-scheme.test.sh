#!/bin/bash
# 群晖版本号映射回归测试
#
# 为什么需要：
#   群晖 INFO 的 version 每段只允许数字，官方 dsh 却带 alpha/rc 后缀。我们把预发布阶段
#   编码进 build 段（alpha+1000 / beta+2000 / rc+3000 / preview+4000 / 正式 9000）。
#   这条映射一旦写错，轻则套件中心排序错乱、重则同 patch 的预发布互相判定"无更新"，
#   而且发出去的包从外面完全看不出来 —— 所以钉死在这。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$ROOT/build/spk-version.py"
PASS=0
FAIL=0

chk_ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
chk_bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "═══ 群晖版本号映射测试 ═══"

# ① 阶段映射
expect() {   # expect <输入> <期望 version> <期望 beta>
  local got beta
  got="$(python3 "$MAP" "$1" 2>/dev/null)"
  beta="$(python3 "$MAP" "$1" --field beta 2>/dev/null)"
  if [ "$got" = "$2" ] && [ "$beta" = "$3" ]; then
    chk_ok "$1 → $2 (beta=$3)"
  else
    chk_bad "$1 → 期望 $2/beta=$3，实际 $got/beta=$beta"
  fi
}

expect 0.2.3-alpha.1 0.2.3-1001 yes
expect 0.2.3-alpha.2 0.2.3-1002 yes
expect 0.2.3-beta.1  0.2.3-2001 yes
expect 0.2.3-rc.1    0.2.3-3001 yes
expect 0.2.2-rc.5    0.2.2-3005 yes
expect 0.2.3         0.2.3-9000 no
expect 0.2.3-20260101 0.2.3-9000 no

# ② 排序正确性（DSM 逐段比数字）：alpha < beta < rc < 正式 < 下一 patch
order_ok="$(python3 - "$MAP" <<'PY'
import subprocess, sys
tool = sys.argv[1]
seq = ['0.2.3-alpha.1', '0.2.3-beta.1', '0.2.3-rc.1', '0.2.3', '0.2.4-alpha.1']
mapped = [subprocess.check_output([sys.executable, tool, v]).decode().strip() for v in seq]
def key(s):
    return tuple(int(x) for x in s.replace('-', '.').split('.'))
print('yes' if all(key(mapped[i]) < key(mapped[i + 1]) for i in range(len(mapped) - 1)) else 'no')
PY
)"
[ "$order_ok" = "yes" ] && chk_ok "阶段顺序 alpha<beta<rc<正式<下一 patch" || chk_bad "阶段顺序错乱"

# ③ 无法映射的输入必须报错（不能静默产出错误版本号）
for bad in 0.2.3-nightly.1 0.2.3-alpha.1234 2.3 ""; do
  if python3 "$MAP" "$bad" >/dev/null 2>&1; then
    chk_bad "非法输入『$bad』未被拒绝"
  else
    chk_ok "非法输入『$bad』被拒绝"
  fi
done

# ④ 幂等：同一输入多次调用结果一致（build 由版本串算出，不依赖计数器）
a="$(python3 "$MAP" 0.2.3-rc.1)"
b="$(python3 "$MAP" 0.2.3-rc.1)"
[ "$a" = "$b" ] && chk_ok "同一输入两次结果一致（$a）" || chk_bad "同一输入结果不稳定"

# ⑤ 接线检查：build-common 必须用映射脚本算 SPK 版本，且把 beta 带进 meta
grep -q 'build/spk-version.py' "$ROOT/build/build-common.sh" \
  && chk_ok "build-common 已接映射脚本" || chk_bad "build-common 未接映射脚本"
grep -q "^SPK_BETA=" "$ROOT/build/build-common.sh" \
  && chk_ok "build-common 定义 SPK_BETA" || chk_bad "build-common 未定义 SPK_BETA"
grep -q "SPK_BETA='" "$ROOT/build/build-common.sh" \
  && chk_ok "build-meta.env 写出 SPK_BETA" || chk_bad "build-meta.env 未写 SPK_BETA"

# ⑥ INFO 必须带 beta 字段（否则预发布在套件中心与正式版无法区分）
grep -q '^beta="\${SPK_BETA' "$ROOT/build/SPK/pack-spk.sh" \
  && chk_ok "INFO 生成含 beta 字段" || chk_bad "INFO 生成缺 beta 字段"

echo "═══ 结果: $PASS 通过 / $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ]
