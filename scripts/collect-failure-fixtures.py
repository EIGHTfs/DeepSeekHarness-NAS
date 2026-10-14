#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""collect-failure-fixtures.py — 采集【历史 CI 失败】作为回归夹具（学习器测试样本）

为什么需要（2026-10-15）：
  自动学习器（learn-prune-whitelist.sh）只能从**真实失败日志**里学。老规则只认模块名，
  遇到"纯类型错"（TS7026/TS2339/TS4112，没有模块名）就瞎了 → 官方 alpha.3 连续构建失败
  （#131/#132）而学习器输出"不是缺包导致" → 看门狗每 30 分钟重试再失败。
  修好之后必须**防退化**：把能找到的历史失败都收成夹具，让 CI 每次构建前都跑一遍。

本脚本做什么：
  ① 列本仓所有 conclusion=failure 的 workflow run（分页）；
  ② 每个 run 取失败 job 的日志，抽取"学习器关心的错误行"（去时间戳/ANSI 转义）；
  ③ 按错误签名去重，落盘成小而可读的夹具：
       test/fixtures/learner/history/<run号>-<job>-<slug>.log   （含来源头注释）
       test/fixtures/learner/history/index.json                 （run/日期/job/签名/重复run）
       test/fixtures/learner/history/proposed-expected.json     （**建议值，必须人工复核**）
  ④ 只读远端、只写夹具目录；**绝不**改白名单、绝不改 expected.json（那是人工据证据定的）。

用法：
  python3 scripts/collect-failure-fixtures.py                # 默认写 test/fixtures/learner/history
  python3 scripts/collect-failure-fixtures.py --limit 40     # 最多采集 40 个 run
  python3 scripts/collect-failure-fixtures.py --dry-run      # 只看会采到什么，不写盘

token：优先环境变量 GH_TOKEN / GITHUB_TOKEN；否则读 工作区/config.json 的 githubToken（本机约定）。
"""
import argparse, json, os, re, subprocess, sys

REPO = os.environ.get('GH_REPO', 'EIGHTfs/DeepSeekHarness-NAS')
API = 'https://api.github.com/repos/' + REPO

# 学习器关心的模式（与 learn-prune-whitelist.sh 的规则对齐；新增规则时这里同步补）
PATTERNS = [
    r"Cannot find package '[^'\n]+'",
    r"Cannot find module [\"'][^\"'\n]+[\"']",
    r"Could not find a declaration file for module [\"'][^\"'\n]+[\"']",
    r"error TS\d+:[^\n]{0,120}",
    r"第\s*\d+\s*轮缺包[:：][^\n]{0,90}",
    r"ERR_PNPM[^\n]{0,100}",
    r"##\[error\][^\n]{0,120}",
    r"failed to import",
    r"did not activate",
    r"✗[^\n]{0,100}",
]
ANSI = re.compile(r'\x1b\[[0-9;]*m')
TS = re.compile(r'^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s*')


def token():
    for k in ('GH_TOKEN', 'GITHUB_TOKEN'):
        if os.environ.get(k):
            return os.environ[k]
    for p in ('/volume13/Artificial Intelligence/DeepSeek/DeepSeekHarness/工作区/config.json',
              os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'config.json')):
        try:
            return json.load(open(p, encoding='utf-8'))['githubToken']
        except Exception:
            pass
    sys.exit('✗ 取不到 token（设 GH_TOKEN 或提供 工作区/config.json）')


def curl(url, tok, timeout=60):
    r = subprocess.run(['curl', '-sL', '--max-time', str(timeout),
                        '-H', 'Authorization: Bearer ' + tok,
                        '-H', 'Accept: application/vnd.github+json', url],
                       capture_output=True, text=True)
    return r.stdout


def api(path, tok):
    try:
        return json.loads(curl(API + path, tok))
    except Exception:
        return {}


def clean(line):
    line = ANSI.sub('', line)
    return TS.sub('', line).rstrip()


def extract(log):
    hits = []
    for p in PATTERNS:
        for m in re.finditer(p, log):
            ln = clean(m.group(0)).strip()
            if ln and ln not in hits:
                hits.append(ln)
    return hits


def slug(text):
    s = re.sub(r'[^A-Za-z0-9]+', '-', text)[:48].strip('-').lower()
    return s or 'nosignal'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='test/fixtures/learner/history')
    ap.add_argument('--limit', type=int, default=50)
    ap.add_argument('--max-lines', type=int, default=60)
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()
    tok = token()

    runs, page = [], 1
    while len(runs) < a.limit and page <= 5:
        d = api('/actions/runs?status=failure&per_page=50&page=%d' % page, tok)
        rs = d.get('workflow_runs') or []
        runs += rs
        if len(rs) < 50:
            break
        page += 1
    print('  历史失败 run: %d 个（上限 %d）' % (len(runs), a.limit))

    seen, out, index = {}, [], []
    for r in runs[:a.limit]:
        rid, num = r['id'], r['run_number']
        jobs = api('/actions/runs/%d/jobs' % rid, tok).get('jobs') or []
        bad = [j for j in jobs if j.get('conclusion') == 'failure']
        if not bad:
            continue
        jname = (bad[0].get('name') or 'job')
        log = curl('%s/actions/jobs/%d/logs' % (API, bad[0]['id']), tok)
        if len(log.strip()) < 200:
            print('  ⚠ #%s 日志为空或过短（%d 字节）→ 跳过（不产出空夹具 ✗）' % (num, len(log.strip())))
            continue
        hits = extract(log)
        if not hits:
            print('  ⚠ #%s 日志 %d 字节但无特征行 → 跳过（避免"空样本"污染回归集 ✗）' % (num, len(log)))
            continue
        sig = '|'.join(sorted({re.sub(r'\([^)]*\)', '(…)', h)[:70] for h in hits}))[:220]
        key = sig or 'NO-SIGNAL'
        if key in seen:
            seen[key]['dups'].append(num)
            continue
        seen[key] = {'run': num, 'dups': []}
        name = '%03d-%s.log' % (num, jname.replace('/', '-'))
        body = '\n'.join(hits[:a.max_lines])
        index.append({'run': num, 'id': rid, 'date': (r.get('run_started_at') or '')[:19],
                      'job': jname, 'file': name, 'hits': len(hits), 'dups': []})
        out.append((name, r, jname, body, hits))
        print('  · #%s %s %s → %s（%d 行特征）' % (num, (r.get('run_started_at') or '')[:10], jname, name, len(hits)))

    for e in index:
        for k, v in seen.items():
            if v['run'] == e['run']:
                e['dups'] = v['dups']

    if a.dry_run:
        print('  （--dry-run：不写盘；将产生 %d 个夹具）' % len(out))
        return 0

    d = a.out
    os.makedirs(d, exist_ok=True)
    for name, r, jname, body, hits in out:
        head = ('# 历史失败夹具（自动采集，请勿手改；来源见 index.json）\n'
                '# run=#%s id=%s date=%s job=%s\n'
                '# 采集: scripts/collect-failure-fixtures.py（只读远端 + 只写本目录）\n'
                % (r['run_number'], r['id'], (r.get('run_started_at') or '')[:19], jname))
        open(os.path.join(d, name), 'w', encoding='utf-8').write(head + body + '\n')
    json.dump(index, open(os.path.join(d, 'index.json'), 'w', encoding='utf-8'),
              ensure_ascii=False, indent=2)
    # 建议值（仅"模块名类"可机械推导；类型错类需人工按证据复核 → 一律标注 TODO）
    prop = {}
    for name, r, jname, body, hits in out:
        got = set()
        for h in hits:
            for m in re.finditer(r"Cannot find (?:package|module) [\"']([^\"']+)[\"']", h):
                mod = m.group(1)
                if mod.startswith('.') or mod.startswith('node:'):
                    continue
                got.add(mod if (mod.startswith('@') and mod.count('/') == 1) else mod.split('/')[0])
            for m in re.finditer(r"Could not find a declaration file for module [\"']([^\"']+)[\"']", h):
                mod = m.group(1)
                got.add('@types/' + mod[1:].replace('/', '__') if (mod.startswith('@') and mod.count('/') == 1) else '@types/' + mod.split('/')[0])
        prop[name] = {'proposed': sorted(got), 'review': 'TODO 人工按证据复核（尤其 TS7026/TS2339 这类无模块名的类型错）'}
    json.dump(prop, open(os.path.join(d, 'proposed-expected.json'), 'w', encoding='utf-8'),
              ensure_ascii=False, indent=2)
    print('  ✓ 已写 %d 个夹具 + index.json + proposed-expected.json → %s' % (len(out), d))
    return 0


if __name__ == '__main__':
    sys.exit(main())
