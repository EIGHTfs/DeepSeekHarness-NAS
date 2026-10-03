#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""README 覆盖度守卫：代码里出现的「脚本名 / 开关名」必须在 README 里出现。

【为什么需要】2026-10-03 机械审计实测：代码中出现的 63 个机制标识里，**35 个在 README
出现 0 次**（`build-lib.sh`、`learn-prune-whitelist.sh`、`fix-runtime-deps.sh`、
`PRUNE_BEFORE_INSTALL/BUILD`、`NPM_MODE`、`PRUNE_COMMON_DIR`、`DRY_RUN` …）。
机制只活在代码注释或数据文件（如 `build-prune-whitelist.json` 的 `_extraNote`）里 ——
"外部需要知道才能正确使用/排障"的东西没有权威出处，于是**经常**漏。

【配套约定（见 README「文档↔代码互引」章）】
  · README 拥有"规范"：机制、开关名+默认值+语义、失败症状对照、验收标准；
  · 代码注释拥有"局部实现"，并**一行指路**到 README 的稳定锚点（`<a id="...">`，禁写行号）；
  · 同一事实只写一次正文 —— 本脚本是这条约定的**机械守卫**：新增脚本/开关没进 README
    就直接失败，避免靠自觉。

【豁免】仅在一次调用内传递、外部无需知道的内部变量列入 EXEMPT；新增豁免必须在此说明理由。

【用法】
  python3 scripts/check-readme-coverage.py          # CI：有缺口则退出码 1
  python3 scripts/check-readme-coverage.py --list   # 只列缺口，始终退出 0
"""
import os
import re
import sys
import collections
import json

# ── 内部实现变量：只在一次调用内传递，外部无需知道（新增请附理由）──
EXEMPT = {
    'DSH_DIR',              # 由 start.sh 自身解析的实例目录（调用者不传）
    'DSH_HOME_RESOLVED',    # 内部解析结果缓存
    'DSH_PID',              # 内部 PID 读取结果
    'DSH_WEB',              # 内部：web 子命令参数
    'DSH_REPAIR_DIR', 'DSH_REPAIR_HOME', 'DSH_REPAIR_HOME_PARENT', 'DSH_REPAIR_NODE',
    'DSH_REPAIR_ENTRY', 'DSH_REPAIR_TSX', 'DSH_REPAIR_DSH_PORT', 'DSH_REPAIR_PROXY_PORT',
    'DSH_REPAIR_CONTAINER_PORT', 'DSH_REPAIR_PID_FILE', 'DSH_REPAIR_TMPDIR',
    # ↑ dsh-repair 内联脚本的一次性传参，由 start.sh 自己拼装
    'FORCE_EXCLUDE',        # 白名单数据结构内的字段名，非用户开关
    'DSH_INSTALL_ROOT',     # migrate-session 内部：目标安装根
    'DSH_PROBE_NAMES',      # fix-runtime-deps 内部：待探测包名列表
    'DSH_PKG_JSON',         # fix-runtime-deps 内部：package.json 路径
    'PRUNE_SCRIPT',         # build-common 内部：prune-target.sh 路径
    'DSH_OWNER',            # build-fpk 内部：目标属主
    'build-placeholder.py',  # 仅被留档脚本 first-build-logic.sh 引用（打包流程不使用）
}

# 扫描时跳过的目录（vendored / 产物 / 垃圾桶 / 官方源码快照）
SKIP_DIRS = {'node_modules', '.git', 'master-build', 'staging', '.trash'}
SKIP_SUBSTR = ('/src/', 'tools/pnpm/dist', 'tools/node-dist', 'assets/')

EXTS = ('.sh', '.py', '.js', '.mjs', '.cjs', '.ts')

# 开关类标识（大写 env/变量）
RE_FLAG = re.compile(r'\b(PRUNE_[A-Z_]+|DSH_[A-Z_]+|SKIP_BUILD|BUILD_STAGE|NPM_MODE|'
                     r'DS_FETCH_[A-Z_]+|FORCE_[A-Z_]+|DRY_RUN)\b')
# 脚本类标识（.sh / .py 文件名）
RE_SCRIPT = re.compile(r'\b([a-z0-9][a-z0-9-]*\.(?:sh|py))\b')
SCRIPT_PREFIX = ('build-', 'gen-', 'learn-', 'prune', 'fix-', 'clean', 'install-', 'fetch-',
                 'verify-', 'migrate-', 'promote-')


def walk(root):
    for dp, dns, fns in os.walk(root):
        if any(s in dp + '/' for s in SKIP_SUBSTR):
            continue
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            if fn.endswith(EXTS):
                yield os.path.join(dp, fn)


def collect(root):
    ids = collections.Counter()
    where = {}
    for path in walk(root):
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        rel = os.path.relpath(path, root)
        for m in RE_FLAG.findall(text):
            ids[m] += 1
            where.setdefault(m, rel)
        for m in RE_SCRIPT.findall(text):
            if m.startswith(SCRIPT_PREFIX):
                ids[m] += 1
                where.setdefault(m, rel)
    return ids, where


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    readme = os.path.join(root, 'README.md')
    list_only = '--list' in sys.argv
    if not os.path.isfile(readme):
        print('✗ 找不到 README.md: %s' % readme, file=sys.stderr)
        return 2
    text = open(readme, encoding='utf-8', errors='replace').read()
    ids, where = collect(root)

    gaps = sorted(((k, v) for k, v in ids.items()
                   if k not in text and k not in EXEMPT), key=lambda kv: -kv[1])
    checked = len([k for k in ids if k not in EXEMPT])

    # --json：供外部工具（如 dsh-git-push 的 doc-coverage 检查器）稳定消费。
    #   逻辑留在本仓库、插件只做封装调用（先例：tree-doc 封装 scripts/tree-doc.mjs）。
    if '--json' in sys.argv:
        print(json.dumps({'ok': not gaps, 'checked': checked, 'exempt': len(EXEMPT),
                          'gaps': [{'id': k, 'count': v, 'example': where[k]} for k, v in gaps]},
                         ensure_ascii=False))
        return 0 if (not gaps or list_only) else 1

    if not gaps:
        print('✓ README 覆盖度通过：%d 个机制标识（豁免 %d）全部在 README 出现'
              % (checked, len(EXEMPT)))
        return 0

    print('✗ README 覆盖度缺口：%d / %d 个机制标识未在 README 出现' % (len(gaps), checked))
    print('  （规则：外部需要知道的脚本/开关必须有 README 出处；确属内部的请加进本脚本 EXEMPT 并写明理由）')
    for k, v in gaps[:40]:
        print('    %-30s 代码 %2d 次  例: %s' % (k, v, where[k]))
    if len(gaps) > 40:
        print('    … 另有 %d 个' % (len(gaps) - 40))
    return 0 if list_only else 1


if __name__ == '__main__':
    sys.exit(main())
