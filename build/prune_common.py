"""DSH 打包裁剪的公共逻辑（2026-10-03 抽出）

【为什么要有这个文件】
prune-target.sh 的三个模式原本是各自内联的 python heredoc：`pkg_name` 在模式 B/C
里**重复定义了两份**，而 `pkg_deps` + 依赖闭包扩展**只有模式 C 有**。结果模式 B
（最终 target）漏了闭包 —— 纯名字白名单只认「被显式列出的包」，外部包自己的
运行时传递依赖不在其中，被无条件删除：

    @deepseek-ai/libreoffice-kit@0.1.1 → fontkit@2.0.4        （dsh-office-to-pdf 挂）
    got@14.6.6                         → @sindresorhus/is@^7.0.1（dsh-otel 挂）
    @modelcontextprotocol/client@2.0.0 → @modelcontextprotocol/core

装完 DSH 启动即 "Cannot find package 'x'"，内置插件 failed to import。实测
10.10.10.64 与 10.10.10.193 两台机器安装的同一个 SPK 全部中招（同源构建缺陷）。
抽成公共模块后 B/C 不可能再各自漂移；以后新增模式请一律 import 这里。
"""

import os
import re


def pkg_name(pnpm_dir):
    """.pnpm 目录名 → 包名

    js-yaml@4.2.0      → js-yaml
    @types+js-yaml@4.0.9 → @types/js-yaml
    """
    base = os.path.basename(pnpm_dir)
    m = re.match(r'(@[^@]+|[^@]+)@', base)
    return m.group(1).replace('+', '/') if m else base


def pkg_deps(full):
    """列出 .pnpm/<pkg>/node_modules/ 下的依赖包名。

    ⚠ 判据必须是 `islink() or exists()`，不能只用 exists()：依赖目标已被删时
      exists() 为假，该依赖会被从闭包里**静默丢掉**，此后即便补包回来也再不会被保留
      （2026-10-03 实测：fontkit / @sindresorhus/is 的软链悬空，闭包再也看不到它们）。
    """
    nm = os.path.join(full, 'node_modules')
    out = set()
    if not os.path.isdir(nm):
        return out
    for e in os.listdir(nm):
        ep = os.path.join(nm, e)
        if e.startswith('@'):
            try:
                for g in os.listdir(ep):
                    gp = os.path.join(ep, g)
                    if os.path.islink(gp) or os.path.exists(gp):
                        out.add('%s/%s' % (e, g))
            except OSError:
                pass
        elif os.path.islink(ep) or os.path.exists(ep):
            out.add(e)
    return out


def index_pnpm(pnpm):
    """包名 → [<.pnpm>/<name>@<ver> 目录]

    跳过 pnpm 的提升链接目录 `node_modules`（名不带版本号）与目录软链。
    """
    name2dirs = {}
    if os.path.isdir(pnpm):
        for d in os.listdir(pnpm):
            full = os.path.join(pnpm, d)
            if os.path.isdir(full) and not os.path.islink(full) and d != 'node_modules':
                name2dirs.setdefault(pkg_name(full), []).append(full)
    return name2dirs


def expand_closure(whitelist, pnpm):
    """从白名单种子出发，沿 .pnpm 依赖软链 BFS，返回 (扩充后的白名单, 闭包集合)。

    必须做闭包的原因见模块 docstring：纯名字白名单会漏掉外部包的传递依赖。
    """
    name2dirs = index_pnpm(pnpm)
    seen = set()
    stack = list(whitelist)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        for d in name2dirs.get(n, []):
            for dep in pkg_deps(d):
                if dep not in seen:
                    stack.append(dep)
    return whitelist | seen, seen
