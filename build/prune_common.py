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


def pkg_runtime_deps(full):
    """只取**运行期**依赖名（package.json 的 dependencies + optionalDependencies）。

    为什么需要它（2026-10-03 实测）：pkg_deps() 读的是 node_modules **目录列表**，会把
    提升进来的 dev 依赖一并纳入 → 闭包爆炸（490 声明 → 1654 闭包 ≈ 整棵 .pnpm）→ 最终裁剪
    几乎不删（保留 1546 / 删除 8）→ target 5.5G → SPK 2GB 撞 600MB 体积门禁。
    运行期闭包只该沿 dependencies 边展开；构建期工具由白名单 extra 负责（模式 C 用全闭包）。
    """
    import json as _json
    out = set()
    try:
        with open(os.path.join(full, 'package.json'), encoding='utf-8') as _f:
            _pj = _json.load(_f)
    except Exception:
        return out
    for _key in ('dependencies', 'optionalDependencies'):
        for _name in (_pj.get(_key) or {}):
            out.add(_name)
    return out


def expand_closure(whitelist, pnpm, runtime_only=False):
    """从白名单种子出发，沿 .pnpm 依赖软链 BFS，返回 (扩充后的白名单, 闭包集合)。

    必须做闭包的原因见模块 docstring：纯名字白名单会漏掉外部包的传递依赖。

    runtime_only=True：只沿**运行期**依赖边展开（package.json 的 dependencies/
      optionalDependencies），用于**最终出货裁剪（模式 B）** —— 决定 SPK 里有什么；
      用目录列表会把 dev 依赖带进来导致闭包爆炸（见 pkg_runtime_deps 注释）。
    runtime_only=False：沿用目录列表（含构建期工具），用于 **build 前裁剪（模式 C）**。
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
            for dep in (pkg_runtime_deps(d) if runtime_only else pkg_deps(d)):
                if dep not in seen:
                    stack.append(dep)
    return whitelist | seen, seen
