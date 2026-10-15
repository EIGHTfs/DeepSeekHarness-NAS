#!/bin/bash
#===============================================================================
# prune-release-assets.test.sh — Release 资产清理的回归测试（架构维度）
#
# 为什么需要（2026-10-15 真机事故）：
#   架构参数化后构建 ARM 包，Release 里的【x86 两个资产被删掉了】✗ ——
#   因为 classify() 的"类别"只含 后缀+链路、**不含架构** ✗
#   → ARM 的 .spk 与 x86 的 .spk 被判为同类 → 本次 dist-main 里只有 ARM 产物 →
#     脚本把同类的 x86 产物当"改名后残留"清掉 ✗（静默丢产物 ✗）
#
# 本测试断言：
#   ① 六个代表性文件名的分类正确（架构进了类别 ✓）
#   ② 类别不同 ⇒ 绝不互相删除（模拟"本次只有 ARM 产物"，x86 资产必须保留 ✓）
#   ③ 非本前缀的资产返回 None（别人的资产绝不碰 ✓）
# 用法: bash test/prune-release-assets.test.sh    （退出码 0=通过）
#===============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('pra', 'scripts/prune-release-assets.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
P = 'DeepSeekHarness-NAS_'
bad = 0

want = {
 'DeepSeekHarness-NAS_x86_64-0.2.1-alpha.3.spk':   ('spk', 'x86_64'),
 'DeepSeekHarness-NAS_armv8-0.2.1-alpha.3.spk':    ('spk', 'armv8'),
 'DeepSeekHarness-NAS_x86-0.2.1-alpha.3.fpk':      ('fpk', 'x86'),
 'DeepSeekHarness-NAS_arm-0.2.1-alpha.3.fpk':      ('fpk', 'arm'),
 'DeepSeekHarness-NAS_x86-0.2.1-alpha.3-npm.fpk':  ('fpk-npm', 'x86'),
 'DeepSeekHarness-Other_x86_64-1.spk':             None,
}
for n, w in want.items():
    got = m.classify(n, P)
    ok = got == w
    print('  %s %-50s → %s' % ('✓' if ok else '✗', n.replace(P, '…'), got))
    if not ok:
        bad += 1
        print('       期望 %s' % (w,))

# ② 类别隔离：本次只有 ARM 产物 → x86 资产不得被删
keep = {'DeepSeekHarness-NAS_armv8-0.2.1-alpha.3.spk', 'DeepSeekHarness-NAS_arm-0.2.1-alpha.3.fpk'}
present = {c for c in (m.classify(n, P) for n in keep) if c}
for n in ('DeepSeekHarness-NAS_x86_64-0.2.1-alpha.3.spk', 'DeepSeekHarness-NAS_x86-0.2.1-alpha.3.fpk'):
    cls = m.classify(n, P)
    would_delete = (cls in present) and (n not in keep)
    ok = not would_delete
    print('  %s %-50s 类别=%s → %s' % ('✓' if ok else '✗', n.replace(P, '…'), cls,
          '会被删 ✗' if would_delete else '保留 ✓'))
    if not ok:
        bad += 1

print('  ── 结果: %s' % ('✓ 通过（架构已进类别，跨架构不会误删 ✓）' if not bad else '✗ %d 项失败' % bad))
sys.exit(1 if bad else 0)
PY
