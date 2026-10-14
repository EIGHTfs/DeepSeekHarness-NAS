#!/bin/bash
#===============================================================================
# learner-dryrun.test.sh — 自动学习器回归测试（固定基线 + 子集判定）
#
# 语义（用户 2026-10-15 定）：
#   · 把【正确识别结果】固化为基线 test/fixtures/learner/baseline.json；
#   · 本测试引用自动学习器跑 dry-run，结果与基线比对：
#        基线 must ⊆ 实际检出   → 通过 ✓（学习器多学是合法改进，允许 ✓）
#        基线里的项缺任何一项   → 失败 ✗（这才是回归）
#        empty:true 的夹具       → 检出必须【为空】✓（负例；否则"期望空"用子集判定会永远通过 ✗）
#   · 更新基线：bash test/learner-dryrun.test.sh --update-baseline
#        （只把"正例"的 must 更新为当前检出；负例保持空并给出告警，避免把瞎学固化成基线 ✗）
#   · 全程 dry-run：断言白名单文件 sha256 不变（绝不写盘 ✓）
# 用法: bash test/learner-dryrun.test.sh [--update-baseline]
#===============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
python3 - "$@" <<'PY'
import hashlib, io, json, os, subprocess, sys

FIX = 'test/fixtures/learner'
BASE = os.path.join(FIX, 'baseline.json')
SRC = os.path.join(FIX, 'src')
WH = 'build/build-prune-whitelist.json'
update = '--update-baseline' in sys.argv

base = json.load(io.open(BASE, encoding='utf-8'))
files = base['files']
h0 = hashlib.sha256(open(WH, 'rb').read()).hexdigest()

fails, warns, newbase = [], [], {}
for name in sorted(files):
    spec = files[name]
    log = os.path.join(FIX, name)
    if not os.path.exists(log):
        fails.append('%s：夹具缺失 ✗' % name); continue
    r = subprocess.run(['bash', 'scripts/learn-prune-whitelist.sh', '--log', log,
                        '--src', SRC, '--json'], capture_output=True, text=True)
    plan = None
    for l in r.stdout.split('\n'):
        if l.startswith('LEARN_PLAN_JSON='):
            plan = json.loads(l.split('=', 1)[1])
    if plan is None:
        fails.append('%s：学习器没输出计划 ✗（stderr: %s）' % (name, r.stderr.strip()[:120])); continue
    got = set(plan.get('learned') or [])
    if spec.get('empty'):
        ok = not got
        print('  %s %-42s 负例：检出必须为空   实际 %s' % ('✓' if ok else '✗', name, sorted(got) or '[]'))
        if not ok:
            fails.append('%s：负例却检出 %s ✗（瞎学 ✗）' % (name, sorted(got)))
            warns.append(name)
        newbase[name] = {'empty': True, 'why': spec.get('why', '')}
    else:
        must = set(spec.get('must') or [])
        missing = sorted(must - got)
        print('  %s %-42s 基线 %2d 项  缺 %s  额外 %s' % ('✓' if not missing else '✗', name, len(must),
              missing or '无', sorted(got - must)[:6] or '无'))
        if missing:
            fails.append('%s：基线要求 %s 未被检出 ✗' % (name, missing))
        newbase[name] = {'must': sorted(got) if update else sorted(must), 'why': spec.get('why', '')}
        if update and got != must:
            print('      ↑ 已把基线更新为当前检出（%d 项）' % len(got))

h1 = hashlib.sha256(open(WH, 'rb').read()).hexdigest()
if h0 != h1:
    fails.append('dry-run 竟然改写了白名单 ✗')
else:
    print('  ✓ dry-run 未写盘（白名单 sha256 不变 %s）' % h0[:16])

if update:
    base['files'] = newbase
    json.dump(base, io.open(BASE, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    io.open(BASE, 'a', encoding='utf-8').write('\n')
    print('  ✓ 基线已更新 → %s（%d 条；负例 %d 条保持空）' % (BASE, len(newbase), len(warns)))
    if warns:
        print('  ⚠ 这些负例被检出内容，已保持"空"基线并告警（请人工复核是否学习器过学）: %s' % warns)

print('  ── 结果: %s' % ('✓ 全部通过（基线 ⊆ 检出 ✓ 负例为空 ✓ 未写盘 ✓）' if not fails else '✗ %d 项失败' % len(fails)))
for f in fails:
    print('     · %s' % f)
sys.exit(1 if fails else 0)
PY
