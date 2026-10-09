#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix-node-links.py —— 补齐 pnpm 的 node_modules 链接（确定性、幂等、纯本地）。

用法:
    ./build/fix-node-links.py <应用体或 target 目录> [--quiet]

为什么需要它（2026-10-09 真机实测，每一句都有现场）：
  DSH 运行时按 node_modules/<包名> 解析依赖，而 pnpm 的链接分三层，任一层缺失都会
  在启动时报 Cannot find module / Cannot find package：
    ① 顶层  node_modules/<包名>              —— 工作区包与 hoisted 依赖
    ② 提升  node_modules/.pnpm/node_modules/<包名>
    ③ 包内  node_modules/.pnpm/<包名>@<版本>/node_modules/<依赖>
  实测缺失现象（fpk 应用体，全新安装后）：
    · apps/cli 声明的 85 个依赖里缺 8 个顶层链接（commander / js-yaml /
      node-addon-require-builtin / @deepseek-ai/cordis* / @deepseek-ai/schemastery）
    · .pnpm/node-addon-require-builtin@0.1.9/… 内部缺 node-addon-native-custom-loader
      → 启动 fatal: dsh: host preparation failed: Cannot find module '…'
      → DSH 退出 code=1 → 守护反复重试 → 用户观感"启动卡很久"
  这三层链接**都可确定性重建**：工作区包 → 指向源码目录；其余 → 指向 .pnpm 实体。

重建规则：
  · 工作区包（任何顶层目录下的 package.json，排除 node_modules）按 name 建索引
  · .pnpm 实体按「包名 → 实体目录」建索引（同时扫描 scoped 的 @scope/name）
  · ① 顶层与 ③ 包内：按各 package.json 的 dependencies/optionalDependencies 建链
  · ② 提升：为每个 .pnpm 实体建一条提升链接（一条覆盖所有消费者，最省）
只增不删：已存在的链接（含正确软链）一律跳过，可安全重复执行。
"""
import glob
import json
import os
import sys

SKIP_TOP = {"node_modules", ".git"}


def ver_key(entity_dir):
    """从 .pnpm/<名字>@<版本>[_peer…] 目录名取版本元组，用于选最高版本。

    实测教训（2026-10-09）：同一包常有多个版本实体（signal-exit@3.0.7 与 4.1.0），
    按**字典序**取第一个会选中 3.0.7，而消费者要的是 4.x —— 症状是
    `Named export 'onExit' not found. 'signal-exit' is a CommonJS module`（v3 无该导出），
    导致 dsh-plugin-manager failed to import。故一律**取最高版本**。
    """
    import re as _re
    m = _re.search(r"@([0-9]+)\.([0-9]+)\.([0-9]+)", entity_dir)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)


def pick_entity(dirs):
    """多版本时取最高版本实体（见 ver_key 的实测教训）。"""
    return sorted(dirs, key=lambda d: ver_key(d))[-1]


def _walk_pkgjson(root, max_depth=6):
    """在 root 下找 package.json，但【绝不进入 node_modules】、【绝不跟随软链】。

    ★ 2026-10-10 实测教训（CI #98 铁证）：原实现用
        glob.glob(os.path.join(root, '**', 'package.json'), recursive=True)
      Python 的 glob 对 `**` 会**跟随软链**下降，而裁剪后的 .pnpm 里实体之间全是软链
      （A→B→C…），遍历量组合爆炸 —— 实测让 build-common.sh 在这一步空转
      【14 分 45 秒】（日志：取消时残留进程 pid (3205) (python3)）。
      改为手工 scandir：遇 node_modules 不下降、is_dir(follow_symlinks=False)，
      遍历量降回“工作区包”本身，秒级完成。
    """
    out = []
    stack = [(root, 0)]
    while stack:
        d, depth = stack.pop()
        if depth > max_depth:
            continue
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            if e.name in ('node_modules', '.git'):
                                continue
                            stack.append((e.path, depth + 1))
                        elif e.name == 'package.json':
                            out.append(e.path)
                    except OSError:
                        continue
        except OSError:
            continue
    return out

def collect_workspace(ad):
    """任何顶层目录下的 package.json → {包名: 目录}。"""
    ws = {}
    for top in os.listdir(ad):
        if top in SKIP_TOP or not os.path.isdir(os.path.join(ad, top)):
            continue
        for pj in _walk_pkgjson(os.path.join(ad, top)):
            try:
                d = json.load(open(pj, encoding="utf-8"))
            except Exception:
                continue
            if d.get("name"):
                ws[d["name"]] = os.path.dirname(pj)
    return ws


def collect_pnpm(ad):
    """枚举 .pnpm 实体 → {包名: [实体目录]}。"""
    pnpm = os.path.join(ad, "node_modules", ".pnpm")
    ent = {}
    if not os.path.isdir(pnpm):
        return pnpm, ent
    for d in sorted(os.listdir(pnpm)):
        p = os.path.join(pnpm, d)
        if not os.path.isdir(p) or d == "node_modules":
            continue
        nmm = os.path.join(p, "node_modules")
        if not os.path.isdir(nmm):
            continue
        for e in os.listdir(nmm):
            if e.startswith("@"):
                sub = os.path.join(nmm, e)
                if os.path.isdir(sub):
                    for s in os.listdir(sub):
                        ent.setdefault(e + "/" + s, []).append(os.path.join(sub, s))
            else:
                ent.setdefault(e, []).append(os.path.join(nmm, e))
    return pnpm, ent


def link(link_path, target, stats):
    if os.path.exists(link_path) or os.path.islink(link_path):
        return False
    try:
        os.makedirs(os.path.dirname(link_path), exist_ok=True)
        os.symlink(os.path.relpath(target, os.path.dirname(link_path)), link_path)
        stats[0] += 1
        return True
    except Exception:
        stats[1] += 1
        return False


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in sys.argv
    if not args:
        print(__doc__)
        return 2
    ad = os.path.abspath(args[0])
    if not os.path.isdir(os.path.join(ad, "node_modules")):
        if not quiet:
            print("  · 无 node_modules，跳过链接补全")
        return 0

    ws = collect_workspace(ad)
    pnpm, ent = collect_pnpm(ad)
    top_stats, dep_stats = [0, 0], [0, 0]

    # ② 提升目录：每个 .pnpm 实体一条（最省、覆盖所有消费者）
    hoist = os.path.join(pnpm, "node_modules")
    if ent:
        os.makedirs(hoist, exist_ok=True)
        for name, dirs in ent.items():
            link(os.path.join(hoist, name), pick_entity(dirs), top_stats)

    # ① 顶层 node_modules/<包名>：★ 2026-10-10 真机验收发现——原来【从未补过这一层】。
    #   Node 从 apps/cli/lib/ 往上找依赖时，命中路径正是 <应用体>/node_modules/<包名>；
    #   而 prune 只保留 .pnpm 实体、顶层链被清掉 → 装完 commander/js-yaml/cordis 全缺
    #   （实测：补 661 条顶层链后应用立刻 running、套件打开 200）。
    #   多版本一律取最高版本（与提升目录同规则，见 ver_key 的实测教训）。
    for _n, _dirs in ent.items():
        link(os.path.join(nm, _n), pick_entity(_dirs), top_stats)
    for _n, _src in ws.items():
        link(os.path.join(nm, _n), _src, top_stats)

    # ③ 包内：按各 package.json 的依赖建链
    # .pnpm 内部实体：结构是已知扁平的（.pnpm/<目录>/node_modules/<包>/package.json），
    # 直接枚举即可，绝不对此做 ** 递归遍历（#98 实测会因软链跟随而爆炸）。
    PNPM_ENTITY_FLAT = True
    for _d in sorted(os.listdir(pnpm)) if os.path.isdir(pnpm) else []:
        _p = os.path.join(pnpm, _d)
        if _d == 'node_modules' or not os.path.isdir(_p):
            continue
        _nmm = os.path.join(_p, 'node_modules')
        if not os.path.isdir(_nmm):
            continue
        try:
            _ents = os.listdir(_nmm)
        except OSError:
            continue
        for _e in _ents:
            if _e.startswith('@'):
                _sub = os.path.join(_nmm, _e)
                try:
                    _subs = os.listdir(_sub)
                except OSError:
                    continue
                _cands = [os.path.join(_sub, _x, 'package.json') for _x in _subs]
            else:
                _cands = [os.path.join(_nmm, _e, 'package.json')]
            for _pj in _cands:
                if not os.path.isfile(_pj):
                    continue
                _dd = os.path.dirname(_pj)
                try:
                    _pp = json.load(open(_pj, encoding='utf-8'))
                except Exception:
                    continue
                for _sec in ('dependencies', 'optionalDependencies'):
                    for _n in (_pp.get(_sec) or {}):
                        _tgt = ws.get(_n) or (pick_entity(ent[_n]) if ent.get(_n) else None)
                        if _tgt:
                            link(os.path.join(_dd, 'node_modules', _n), _tgt, dep_stats)
    _SKIP_TOPLEVEL_DEP_SCAN = True
    for top in os.listdir(ad):
        if top in SKIP_TOP:
            continue
        if _SKIP_TOPLEVEL_DEP_SCAN and top == 'node_modules':
            continue
        for pj in _walk_pkgjson(os.path.join(ad, top)):
            d = os.path.dirname(pj)
            try:
                p = json.load(open(pj, encoding="utf-8"))
            except Exception:
                continue
            for sec in ("dependencies", "optionalDependencies"):
                for n in (p.get(sec) or {}):
                    tgt = ws.get(n) or (pick_entity(ent[n]) if ent.get(n) else None)
                    if tgt:
                        link(os.path.join(d, "node_modules", n), tgt, dep_stats)

    if not quiet:
        print("  ✓ 链接补全: 提升目录新建 %d 条（跳过 %d）；包内依赖新建 %d 条（跳过 %d）"
              % (top_stats[0], top_stats[1], dep_stats[0], dep_stats[1]))
        print("    工作区包 %d 个，.pnpm 实体包名 %d 个" % (len(ws), len(ent)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
