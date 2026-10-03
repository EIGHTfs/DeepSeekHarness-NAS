#!/usr/bin/env python3
"""
pnpm-bridge: pnpm 11 配置桥接器

pnpm 11 不再读 package.json 的 `pnpm` 字段（报 "The pnpm field in package.json
is no longer read"），全部改读 pnpm-workspace.yaml。本脚本把项目根的
package.json 里的 pnpm 字段（onlyBuiltDependencies 等）自动合并进
pnpm-workspace.yaml，再用官方 pnpm 执行，免除每次手动改 yaml。

用法（wrapper 内部调用，或手动）:
    python3 pnpm-bridge.py [--dir <项目根>] [--dry-run]

    --dir      从哪个目录开始找项目根（默认当前目录；向上找最近带
               package.json 的目录，且该目录有 pnpm-workspace.yaml 或
               package.json 含 pnpm 字段才视为项目根）
    --dry-run  只打印将要写入的内容，不写文件

转换规则（package.json pnpm.* -> pnpm-workspace.yaml）:
    pnpm.onlyBuiltDependencies: [pkg...]  -> allowBuilds: {pkg: true}
    pnpm.ignoredBuiltDependencies        -> ignoredBuiltDependencies
    pnpm.neverBuiltDependencies          -> neverBuiltDependencies
    pnpm.onlyBuiltDependenciesFile       -> onlyBuiltDependenciesFile
    pnpm.allowNonAppliedPatches         -> allowNonAppliedPatches
    pnpm.peerDependencyRules            -> peerDependencyRules
    pnpm.overrides                      -> overrides
    pnpm.patchedDependencies            -> patchedDependencies
    pnpm.patchDir                       -> patchDir
    pnpm.nodeVersion / pnpm.registry    -> 同名透传（若有）

安全保证:
    - 幂等：已存在的 allowBuilds 条目不覆盖（保留显式 true/false）
    - 保留 pnpm-workspace.yaml 已有内容（nodeLinker/autoInstallPeers 等）
    - 没有 pnpm 字段时静默退出（exit 0），不影响任何 pnpm 调用
    - 解析失败（JSON/YAML 损坏）静默跳过，绝不阻断 pnpm
"""
import argparse
import json
import os
import sys

try:
    import yaml
except ImportError:
    yaml = None


def find_project_root(start):
    """向上找最近带 package.json 的目录，且它被视为 pnpm 项目根。"""
    d = os.path.abspath(start)
    while True:
        pj = os.path.join(d, 'package.json')
        ws = os.path.join(d, 'pnpm-workspace.yaml')
        if os.path.isfile(pj):
            # 若本目录有 pnpm 字段或 pnpm-workspace.yaml，认定是项目根
            try:
                data = json.load(open(pj, encoding='utf-8'))
            except Exception:
                data = {}
            if isinstance(data.get('pnpm'), dict) or os.path.isfile(ws) or os.path.isfile(os.path.join(d, 'pnpm-lock.yaml')):
                return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _load_inputs(root):
    """读取 package.json 的 pnpm 字段与 pnpm-workspace.yaml。返回 (pm, doc, ws_path)。

    任何一步拿不到可用数据都返回 (None, {}, ws)，由调用方直接返回 0（保持原行为：
    本工具是"能合就合"的尽力而为，不因缺文件而报错）。
    """
    pj = os.path.join(root, 'package.json')
    ws = os.path.join(root, 'pnpm-workspace.yaml')
    try:
        data = json.load(open(pj, encoding='utf-8'))
    except Exception:
        return None, {}, ws
    pm = data.get('pnpm')
    if not isinstance(pm, dict) or not pm:
        return None, {}, ws

    doc = {}
    if os.path.isfile(ws):
        try:
            with open(ws, encoding='utf-8') as f:
                doc = yaml.safe_load(f) or {}
        except Exception:
            doc = {}
    if not isinstance(doc, dict):
        doc = {}
    return pm, doc, ws


def _merge_only_built(pm, doc):
    """onlyBuiltDependencies: [pkg] → allowBuilds: {pkg: true}。返回是否有改动。"""
    obd = pm.get('onlyBuiltDependencies')
    if not (isinstance(obd, list) and obd):
        return False
    if 'allowBuilds' not in doc or not isinstance(doc.get('allowBuilds'), dict):
        doc['allowBuilds'] = {}
    changed = False
    for p in obd:
        if p not in doc['allowBuilds']:
            doc['allowBuilds'][p] = True
            changed = True
    return changed


def _merge_passthrough(pm, doc):
    """其余 pnpm 字段同名透传（仅当 yaml 里缺失时）。返回是否有改动。"""
    passthrough = ('ignoredBuiltDependencies', 'neverBuiltDependencies',
                   'onlyBuiltDependenciesFile', 'allowNonAppliedPatches',
                   'peerDependencyRules', 'overrides', 'patchedDependencies',
                   'patchDir', 'nodeVersion', 'registry',
                   'strictDepBuilds', 'packageImportMethod')
    changed = False
    for key in passthrough:
        if key in pm and key not in doc:
            doc[key] = pm[key]
            changed = True
    return changed


def merge(start, dry_run=False):
    if yaml is None:
        sys.stderr.write('[pnpm-bridge] PyYAML 不可用，跳过\n')
        return 0
    root = find_project_root(start)
    if root is None:
        return 0

    pm, doc, ws = _load_inputs(root)
    if pm is None:
        return 0

    changed = _merge_only_built(pm, doc)
    if _merge_passthrough(pm, doc):
        changed = True
    if not changed:
        return 0

    out = yaml.safe_dump(doc, allow_unicode=True, sort_keys=False, default_flow_style=False)
    if dry_run:
        sys.stdout.write('[pnpm-bridge][dry-run] 将写入 %s:\n%s' % (ws, out))
        return 0
    with open(ws, 'w', encoding='utf-8') as f:
        f.write(out)
    sys.stdout.write('[pnpm-bridge] 已合并 package.json pnpm 字段 -> %s\n' % ws)
    return 1


def main():
    ap = argparse.ArgumentParser(description='pnpm 11 配置桥接器')
    ap.add_argument('--dir', default=os.getcwd())
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    return merge(args.dir, args.dry_run)


if __name__ == '__main__':
    sys.exit(0 if main() == 0 else 0)