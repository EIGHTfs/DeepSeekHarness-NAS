#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查仓库里有没有把 GitHub 凭据写进文件（尤其是本机部署后忘记清空的那种）。

为什么需要这道守卫：`scripts/watch-official-local.sh` 按部署口径把 token 写成脚本内常量，
入库版本留空、本机部署时手动填入。危险点在于「本机填了 → 某次 git add -A → 凭据进公开库」。
本守卫在 CI 里扫一遍，命中就失败，避免把凭据推到公开仓库。

判据（命中任一即失败）：
  1. 出现 GitHub 令牌形态的字符串（ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_ 前缀 + 长随机串）
  2. 给 GITHUB_TOKEN 赋了非空字面值（这类文件应留空；变量引用与占位符放行）

     注：本条判据的示例不能直接写成会被自身命中的形态，否则守卫会把自己的说明文字判成凭据
     （CI 曾因此红过一次：说明文字里的赋值示例被正则匹配）。所以这里只描述语义、不给字面例。
  3. 出现形如 Authorization: Bearer <非空> 的硬编码头

只扫源码与脚本（*.sh / *.py / *.yml / *.yaml / *.md / *.json），跳过 .git 与官方文档快照目录
（`docs/官方文档/` 下是上游原文，可能含示例串，不作为本仓的凭据风险）。

用法：
    python3 scripts/check-no-secrets.py            # 扫全仓
    python3 scripts/check-no-secrets.py <路径>...  # 只扫指定文件/目录
退出码：0 = 干净；1 = 发现问题
"""

import os
import re
import subprocess
import sys

# 允许被扫描的扩展名（其余文件跳过，避免二进制误判）
SCANNED_SUFFIXES = ('.sh', '.py', '.yml', '.yaml', '.md', '.json', '.js', '.mjs', '.cjs')

# 扫描时跳过的目录
SKIPPED_DIRS = {
    '.git',
    'node_modules',
    'docs/官方文档',      # 上游官方文档原文，含示例串不代表本仓持有凭据
    '.trash',
    'build/master-build',
    'build/staging',
    'release',
    'assets/pnpm-store',
}

# GitHub 令牌形态：前缀 + 足够长的随机串
TOKEN_PATTERNS = [
    re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
    re.compile(r'\bgithub_pat_[A-Za-z0-9_]{20,}'),
]

# 应保持空值的赋值；允许空字符串、空引号、或明显占位符
EMPTY_ONLY_ASSIGNMENTS = [
    re.compile(r'GITHUB_TOKEN\s*=\s*"([^"]*)"'),
    re.compile(r'GITHUB_TOKEN\s*=\s*\'([^\']*)\''),
    re.compile(r'GITHUB_TOKEN\s*:(?!-)\s*([^\s#]+)'),
]

# 明确的占位符写法，出现在上面捕获组里视为安全
PLACEHOLDER_VALUES = {
    '',
    '__SET_LOCAL__',
    '__REPLACE_ME__',
    '<your-token>',
    '<TOKEN>',
    '${{ secrets.GITHUB_TOKEN }}',
    '${GITHUB_TOKEN}',
    '$GITHUB_TOKEN',
}

# 硬编码的 Bearer 头
BEARER_PATTERN = re.compile(r'Authorization:\s*Bearer\s+([A-Za-z0-9_\-\.]{16,})')


def is_variable_reference(value: str) -> bool:
    """值来自变量/表达式（$FOO、${FOO:-}、${{ secrets.X }}）时不算硬编码凭据。"""
    stripped = value.strip()
    return stripped.startswith('$')


def is_skipped(path: str) -> bool:
    normalized = path.replace(os.sep, '/')
    for skipped in SKIPPED_DIRS:
        if f'/{skipped}/' in f'/{normalized}/' or normalized.startswith(f'{skipped}/'):
            return True
    return False


def iter_tracked_files():
    """只扫 git 跟踪的文件。

    为什么不用 os.walk 全仓：语义上要查的是「即将入库的内容」，未跟踪文件不在范围内；
    工程上在 CIFS/SMB 挂载上遍历整棵树要几分钟甚至超时（实测 120 秒未完成），而
    `git ls-files` 走索引，几百个文件是毫秒级。git 不可用时才退回目录遍历。
    """
    try:
        completed = subprocess.run(
            ['git', 'ls-files'],
            capture_output=True, text=True, timeout=60, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not completed.stdout.strip():
        return None
    return [line for line in completed.stdout.splitlines() if line.endswith(SCANNED_SUFFIXES)]


def iter_files(targets):
    for target in targets:
        if os.path.isfile(target):
            yield target
            continue
        for root, dirnames, filenames in os.walk(target):
            dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules')]
            for filename in filenames:
                if filename.endswith(SCANNED_SUFFIXES):
                    yield os.path.join(root, filename)


def scan_file(path: str):
    findings = []
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as handle:
            for line_number, line in enumerate(handle, 1):
                if is_skipped(path):
                    return findings
                for pattern in TOKEN_PATTERNS:
                    if pattern.search(line):
                        findings.append((path, line_number, '出现 GitHub 令牌形态字符串'))
                for pattern in EMPTY_ONLY_ASSIGNMENTS:
                    match = pattern.search(line)
                    if not match:
                        continue
                    value = match.group(1).strip()
                    if value in PLACEHOLDER_VALUES or is_variable_reference(value):
                        continue
                    findings.append((path, line_number, 'GITHUB_TOKEN 被赋了非空值（应留空或占位）'))
                match = BEARER_PATTERN.search(line)
                if match and match.group(1) not in PLACEHOLDER_VALUES:
                    findings.append((path, line_number, '硬编码了 Bearer 令牌'))
    except OSError as error:
        findings.append((path, 0, f'读取失败：{error}'))
    return findings


def main(argv):
    explicit_targets = argv[1:]
    targets = explicit_targets or ['.']
    findings = []
    scanned = 0

    # 未显式指定路径时，优先用 git 跟踪集（快且语义正确）；否则按给定路径遍历
    tracked = None if explicit_targets else iter_tracked_files()
    candidates = tracked if tracked is not None else iter_files(targets)

    for path in candidates:
        scanned += 1
        findings.extend(scan_file(path))

    if findings:
        print(f'✗ 凭据检查失败（扫描 {scanned} 个文件，命中 {len(findings)} 处）：')
        for path, line_number, reason in findings:
            print(f'  - {path}:{line_number}  {reason}')
        print('  处置：把凭据清空/改占位；本机真实值不要提交（必要时 git update-index --skip-worktree <文件>）')
        return 1

    print(f'✓ 凭据检查通过（扫描 {scanned} 个文件，未发现令牌或非空 GITHUB_TOKEN）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
