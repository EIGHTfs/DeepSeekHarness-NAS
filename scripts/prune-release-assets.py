#!/usr/bin/env python3
"""prune-release-assets.py —— 清理 Release 里「改名后残留」的旧产物资产。

【为什么需要】
发布用的是 softprops/action-gh-release，它只**替换同名资产**；一旦产物**改名**
（例如 SPK 从 `DeepSeekHarness-NAS_x86_64-0.2.1.spk` 改成 `…-0.2.1-alpha.1.spk`），
旧名字的资产就会一直留在 Release 里，让下载者选错包。实测遇到过：同一个 Release 同时
挂着新旧两个 SPK。

【安全设计（宁可少删，绝不错删）】
1) 只处理名字以 --prefix 开头的资产（默认 `DeepSeekHarness-NAS_`）—— 别人的资产绝不碰；
2) **只清理「本次构建确实产出过的类别」**。类别 = 架构 + 后缀 + 链路，由 keep 清单里的
   文件名推导（spk 源码链 / fpk 源码链 / fpk npm 链）。若某类别本次没产出
   （例如把 vars.BUILD_FPK 设为 false），该类别**一个都不删** —— 避免把上一轮留下的
   另一链产物误删，那种误删是「静默丢产物」，比留个旧文件严重得多；
3) keep 清单为空时**直接拒绝执行**（没有比对基准就不删任何东西）；
4) 支持 --dry-run：只打印将删什么，不真删；正常模式也会逐条打印动作与汇总。

【用法】
    GH_TOKEN=… GITHUB_REPOSITORY=owner/repo \\
      python3 scripts/prune-release-assets.py --tag dsh-v0.2.1-alpha.1 --keep-from dist-main

    先看效果（不删）：  … --dry-run
    换仓库/前缀：      … --repo owner/repo --prefix 'MyPkg_'

退出码：0 成功（含「无需清理」）；1 参数/网络/接口错误；2 因为安全规则拒绝执行。
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = 'https://api.github.com'


def _die(code, msg):
    sys.stderr.write('[prune-release-assets] %s\n' % msg)
    sys.exit(code)


def _token():
    """从环境取 token（CI 用 secrets.GITHUB_TOKEN；本地可 export GH_TOKEN）。"""
    for key in ('GH_TOKEN', 'GITHUB_TOKEN'):
        v = os.environ.get(key)
        if v:
            return v.strip()
    _die(1, '缺少 GH_TOKEN / GITHUB_TOKEN 环境变量')


def _repo():
    r = os.environ.get('GITHUB_REPOSITORY', '')
    if '/' not in r:
        _die(1, '缺少 GITHUB_REPOSITORY（形如 owner/repo），或用 --repo 指定')
    return r


def _api(method, path, token, body=None):
    """最小 GitHub API 调用（纯标准库，避免额外依赖）。返回 (状态码, 解析后的 JSON 或 None)。"""
    url = API + path
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + token)
    req.add_header('Accept', 'application/vnd.github+json')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode('utf-8')
            return resp.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', 'replace')
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'message': raw[:200]}


def classify(name, prefix):
    """把资产名归到「类别」：同类别才允许互相替换。

    类别只由**后缀 + 链路**决定，刻意**不含版本号** —— 因为要清理的正是「同一份产物、
    改了版本写法」的旧名字（例如 0.2.1 与 0.2.1-alpha.1）。
    返回 None 表示不是我们关心的产物类型。
    """
    if not name.startswith(prefix):
        return None
    if name.endswith('.spk'):
        return 'spk'
    if name.endswith('-npm.fpk'):
        return 'fpk-npm'
    if name.endswith('.fpk'):
        return 'fpk'
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description='清理 Release 里改名后残留的旧产物资产')
    ap.add_argument('--tag', required=True, help='Release tag（与构建发布的 tag 一致）')
    ap.add_argument('--keep-from', required=True,
                    help='本次产物的目录（取其下文件的文件名作为保留清单）')
    ap.add_argument('--repo', default=None, help='owner/repo（默认取 GITHUB_REPOSITORY）')
    ap.add_argument('--prefix', default='DeepSeekHarness-NAS_',
                    help='只清理此前缀开头的资产（默认 DeepSeekHarness-NAS_）')
    ap.add_argument('--dry-run', action='store_true', help='只打印将删什么，不真删')
    args = ap.parse_args(argv)

    repo = args.repo or _repo()
    token = _token()

    # ---- 保留清单 ----
    if not os.path.isdir(args.keep_from):
        _die(1, '产物目录不存在: %s' % args.keep_from)
    keep = set()
    for fn in os.listdir(args.keep_from):
        p = os.path.join(args.keep_from, fn)
        if os.path.isfile(p):
            keep.add(fn)
    if not keep:
        _die(2, '保留清单为空（%s 下没有文件）—— 没有比对基准，拒绝执行' % args.keep_from)
    present = {c for c in (classify(n, args.prefix) for n in keep) if c}
    print('[prune] 保留清单 %d 项，涉及类别: %s' % (len(keep), sorted(present) or '（无）'))

    # ---- 取该 tag 的 Release ----
    status, rel = _api('GET', '/repos/%s/releases/tags/%s' % (repo, args.tag), token)
    if status == 404:
        print('[prune] Release %s 不存在，无需清理' % args.tag)
        return 0
    if status != 200 or not isinstance(rel, dict):
        _die(1, '取 Release 失败: HTTP %s %s' % (status, str(rel)[:160]))

    assets = rel.get('assets') or []
    print('[prune] Release %s 现有资产 %d 个' % (args.tag, len(assets)))

    # ---- 逐个判定 ----
    removed, kept, skipped = [], [], []
    for a in assets:
        name = a.get('name') or ''
        cls = classify(name, args.prefix)
        if cls is None:
            skipped.append((name, '非本包资产（前缀/类型不匹配）'))
            continue
        if name in keep:
            kept.append(name)
            continue
        if cls not in present:
            # 本次没产出这个类别 → 一律不动（防误删另一条链的产物）
            skipped.append((name, '类别 %s 本次未产出，按安全规则不删' % cls))
            continue
        if args.dry_run:
            print('  [dry-run] 将删除 %s（类别 %s，已被本次同类产物取代）' % (name, cls))
            removed.append(name)
            continue
        st, _ = _api('DELETE', '/repos/%s/releases/assets/%s' % (repo, a.get('id')), token)
        if st in (204, 200):
            print('  已删除 %s（类别 %s）' % (name, cls))
            removed.append(name)
        else:
            print('  ✗ 删除失败 %s: HTTP %s' % (name, st))
            return 1

    for n in kept:
        print('  保留 %s（本次产物）' % n)
    for n, why in skipped:
        print('  跳过 %s（%s）' % (n, why))

    verb = '将删除' if args.dry_run else '已删除'
    print('[prune] 完成：%s %d 个，保留 %d 个，跳过 %d 个%s'
          % (verb, len(removed), len(kept), len(skipped), '（dry-run 未真删）' if args.dry_run else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
