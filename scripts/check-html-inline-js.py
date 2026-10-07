#!/usr/bin/env python3
"""check-html-inline-js.py —— 断言 HTML 里的【内联 JS】语法合法（真让 JS 引擎解析一次）

【为什么需要】（2026-10-05 实测事故，潜伏了一整天）
`web-install/install.html` 的"卸载确认"文案里出现了**跨行的单引号字符串**（裸换行）：

    const _msg = '确定要远程卸载 ' + host.value.trim() + ' 上的套件吗？
                                                  ← 这里换行，字符串未闭合
    ' +
    （由 ffa2a70 引入）

这是**解析期**错误 → 整段内联脚本**一行都不执行** → 页面所有按钮失效
（配置回填 / 探测 / 安装 / 修复 / 检查 / 卸载 / 历史 / 构建 全部无反应）。

最坑的地方是：这种故障**看不出来** ——
  · 页面照常返回 HTTP 200，DOM 结构完好，肉眼以为"就是没反应"；
  · grep id、grep 函数名、检查元素是否存在……**全都查不出来**；
  · 现有守卫只覆盖 `.sh`（bash -n）与 `.py`（ast.parse），`.html` 内联 JS 是空白。
所以本守卫的做法就是**真的调用一次 JS 解析器**（node --check），而不是做启发式猜测。

【做法】
  1) 取 git 跟踪的 HTML（默认 web-install/*.html，--glob 可覆盖；排除 vendored tools/）；
  2) 抽出每个 <script>…</script>：跳过带 src= 的外链、跳过非 JS 的 type（如 application/json）；
  3) 每个块写临时文件后 `node --check`；失败则报出「HTML 文件 + 块起始行 + node 原始报错」；
  4) node 不可用时**报错退出（退出码 1）而不是静默跳过** —— 避免"看起来绿、其实没查"。
     （CI 的 ubuntu-latest 自带 node，本机也有；真的没有时应该显式暴露出来。）

用法：python3 scripts/check-html-inline-js.py [--glob 'web-install/*.html'] [--list]
退出码：0 通过 / 1 有语法错误或环境不具备
"""
import argparse
import glob as globmod
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GLOB = 'web-install/*.html'

# <script ...> ... </script>；捕获属性与内容
SCRIPT_RE = re.compile(r'<script\b([^>]*)>(.*?)</script>', re.S | re.I)


def tracked_html(pattern):
    """git 跟踪 + 匹配 pattern 的 HTML（排除 vendored tools/），返回仓库相对路径。"""
    try:
        out = subprocess.run(['git', 'ls-files', '--', '*.html'],
                             cwd=ROOT, capture_output=True, text=True, timeout=30)
        files = [f for f in out.stdout.split('\n') if f.strip()]
    except Exception:
        files = []
    if not files:                      # 非 git 环境（例如某些 CI 片段）：退回文件系统扫描
        files = [os.path.relpath(p, ROOT) for p in globmod.glob(os.path.join(ROOT, pattern))]
    pat = pattern.replace('\\', '/')
    return sorted(f for f in files
                  if not f.startswith('tools/')
                  and globmod.fnmatch.fnmatch(f, pat))


def js_blocks(text):
    """返回 [(块起始行号, 代码)]，只取真正的 JS 块。"""
    out = []
    for m in SCRIPT_RE.finditer(text):
        attrs, body = m.group(1), m.group(2)
        if re.search(r'\bsrc\s*=', attrs, re.I):        # 外链脚本不在本守卫范围
            continue
        tm = re.search(r'\btype\s*=\s*["\']([^"\']+)["\']', attrs, re.I)
        if tm:
            t = tm.group(1).strip().lower()
            if t and not (t.endswith('javascript') or t in ('module', 'text/ecmascript')):
                continue                                # application/json 之类：不是 JS
        start_line = text.count('\n', 0, m.start(2)) + 1
        out.append((start_line, body))
    return out


def check_file(rel, node):
    path = os.path.join(ROOT, rel)
    with open(path, encoding='utf-8') as f:
        text = f.read()
    problems = []
    blocks = js_blocks(text)
    for start_line, code in blocks:
        if not code.strip():
            continue
        fd, tmp = tempfile.mkstemp(suffix='.js')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                f.write(code)
            r = subprocess.run([node, '--check', tmp], capture_output=True, text=True, timeout=60)
            if r.returncode != 0:
                err = (r.stderr or r.stdout).strip().split('\n')
                # 把 node 的行号换算回 HTML 行号，方便直接定位
                line_no = None
                for ln in err:
                    mm = re.search(re.escape(tmp) + r':(\d+)', ln)
                    if mm:
                        line_no = start_line + int(mm.group(1)) - 1
                        break
                detail = '\n      '.join(err[:6])
                problems.append('%s:%s（内联 <script> 起始于第 %d 行）\n      %s'
                                % (rel, line_no if line_no else '?', start_line, detail))
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return problems, len(blocks)


def main(argv=None):
    ap = argparse.ArgumentParser(description='断言 HTML 内联 JS 语法合法（node --check）')
    ap.add_argument('--glob', default=DEFAULT_GLOB, help='匹配的 HTML（默认 %s）' % DEFAULT_GLOB)
    ap.add_argument('--list', action='store_true', help='只列出将被检查的文件后退出')
    args = ap.parse_args(argv)

    files = tracked_html(args.glob)
    if args.list:
        print('\n'.join(files))
        return 0
    if not files:
        sys.stderr.write('[!] 没有匹配到 HTML 文件（--glob %s）\n' % args.glob)
        return 1

    node = shutil.which('node')
    if not node:
        sys.stderr.write('[!] 找不到 node —— 本守卫需要真实 JS 解析器，'
                         '拒绝静默跳过（否则等于没查）\n')
        return 1

    all_problems = []
    total_blocks = 0
    for rel in files:
        problems, n = check_file(rel, node)
        total_blocks += n
        all_problems += problems

    if all_problems:
        sys.stderr.write('✗ 内联 JS 语法守卫失败（%d 项）：\n' % len(all_problems))
        for p in all_problems:
            sys.stderr.write('   - %s\n' % p)
        sys.stderr.write('   提示：解析期错误会让**整段脚本都不执行**（按钮全失效），'
                         '而页面照常返回 200 —— 必须修掉才能上线。\n')
        return 1

    print('✓ 内联 JS 语法守卫通过（%d 个文件 / %d 个 <script> 块，均由 node --check 解析）'
          % (len(files), total_blocks))
    return 0


if __name__ == '__main__':
    sys.exit(main())
