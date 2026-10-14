#!/bin/bash
#===============================================================================
# learner-dryrun.test.sh — 自动学习器（learn-prune-whitelist.sh）的【回归测试】
#
# 为什么需要：2026-10-14 官方 alpha.3 构建连续失败（#131/#132）时，学习器输出
#   "白名单无变化（本次失败不是缺包导致）"—— 因为老规则只认日志里的模块名，
#   而那次失败是【纯类型错】（TS7026/TS2339/TS4112，没有模块名）→ 学习器瞎了 ✗
#   → 看门狗每 30 分钟重试再失败，官方新版一直出不来包。
#
# 本测试用【真实失败日志片段】当夹具（test/fixtures/learner/），断言：
#   ① 该学的必须学到（TS7026 → 源码声明的类型包；TS2307/TS7016 → 模块名/@types）
#   ② 不该学的一个都不学（反例：只有 TS2339、无 JSX 信号 → 必须为空 ✓ 守住"不猜"）
#   ③ 全程 --dry-run 不写盘（白名单文件哈希不变）
# 用法: bash test/learner-dryrun.test.sh   （退出码 0=通过）
#===============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FIX=test/fixtures/learner
WH=build/build-prune-whitelist.json
fail=0
before=$(sha256sum "$WH" | cut -d' ' -f1)

python3 - "$FIX" "$WH" <<'PY'
import json, os, subprocess, sys
fix, wh = sys.argv[1], sys.argv[2]
exp = json.load(open(os.path.join(fix, 'expected.json'), encoding='utf-8'))
before = open(wh, 'rb').read()
bad = 0
for name, want in exp.items():
    log = os.path.join(fix, name)
    if not os.path.exists(log):
        print('  ✗ 夹具缺失: %s' % log); bad += 1; continue
    r = subprocess.run(['bash', 'scripts/learn-prune-whitelist.sh', '--log', log,
                        '--src', os.path.join(fix, 'src'), '--json'],
                       capture_output=True, text=True)
    plan = None
    for line in r.stdout.split('\n'):
        if line.startswith('LEARN_PLAN_JSON='):
            plan = json.loads(line.split('=', 1)[1])
    if plan is None:
        print('  ✗ %-28s 没拿到 LEARN_PLAN_JSON（脚本输出异常）' % name)
        print('     stderr: %s' % r.stderr.strip()[:200]); bad += 1; continue
    got = sorted(plan.get('learned') or [])
    ok = got == sorted(want)
    print('  %s %-28s 期望 %s' % ('✓' if ok else '✗', name, sorted(want)))
    if not ok:
        print('       实际 %s' % got); bad += 1
after = open(wh, 'rb').read()
if before != after:
    print('  ✗ dry-run 竟然改写了白名单（必须只读！）'); bad += 1
else:
    print('  ✓ dry-run 未写盘（白名单哈希不变）')
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" -ne 0 ] && fail=1
after=$(sha256sum "$WH" | cut -d' ' -f1)
[ "$before" = "$after" ] || { echo "  ✗ 白名单被改写 ✗"; fail=1; }
echo "  ── 结果: $([ "$fail" = 0 ] && echo '✓ 全部通过（学习器检出能力与"不猜"边界都受保护 ✓）' || echo '✗ 有失败 ✗')"
exit "$fail"
