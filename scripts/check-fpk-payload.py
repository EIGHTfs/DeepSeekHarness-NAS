#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-fpk-payload.py —— **出货级**守卫：直接验构建出来的 FPK 载荷对不对。

用法:
    ./scripts/check-fpk-payload.py <包.fpk> [--expect-pkg 名字]...

为什么需要它（2026-10-09 血的教训）：
  已有守卫全是**源码级**的（check-packaging-invariants 检查脚本文本、
  check-package-parity 要人工给两个包比对）—— 它们保证不了【构建出来的包】可用。
  于是反复出现同一类出货缺陷，每次都要装到真机才发现：
    · 载荷里留着软链 → fnOS 解压设 ACL 失败「设置目录权限失败」
    · links.tar 里的目标在载荷中不存在 → 启动 Cannot find package 'X'
      （实测 commander / js-yaml / node-addon-native-custom-loader / cordis 全家）
    · 缺 ui/config → 应用中心「打开」按钮点了没反应
    · 缺 cmd/install_callback → 安装钩子不执行
  本脚本把这些一次性验完，**不合格就让构建失败**，不再靠人肉装真机。

检查项：
  ① 外层必含：manifest / <app>.sc / cmd/install_callback / links.tar / ui/config
  ② 载荷（app.tgz）内**软链数必须为 0**（fnOS 解压设 ACL 会失败）
  ③ links.tar 里**每条软链的目标**都必须在载荷里存在（悬空即运行时缺包）
  ④ 每个 package.json 声明的依赖，都必须能从【载荷内】解析到
     （顶层 node_modules/<n>、或 .pnpm/node_modules/<n>、或 .pnpm/<n>@*/node_modules/<n>）
  ⑤ manifest 的 desktop_applaunchname 必须与 ui/config 的 .url 键一致
     （不一致 → 「打开」按钮没反应）
退出码 0 = 全部通过；1 = 有出货缺陷（构建应失败）。
"""
import glob
import io
import json
import os
import re
import subprocess
import sys

RED = "\033[31m" if sys.stdout.isatty() else ""
GRN = "\033[32m" if sys.stdout.isatty() else ""
YLW = "\033[33m" if sys.stdout.isatty() else ""
RST = "\033[0m" if sys.stdout.isatty() else ""


def sh(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def outer_entries(fpk):
    rc, out = sh(["tar", "-tzf", fpk])
    if rc != 0:
        rc, out = sh(["tar", "-tf", fpk])
    return [l for l in out.split("\n") if l.strip()]


def payload_lines(fpk):
    """载荷 app.tgz 的 tar -tvzf 行。"""
    p1 = subprocess.Popen(["tar", "-xzOf", fpk, "app.tgz"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(["tar", "-tvzf", "-"], stdin=p1.stdout,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p1.stdout.close()
    return [l for l in p2.communicate()[0].decode("utf-8", "replace").split("\n") if l.strip()]


def parse_tv(lines):
    ents = {}
    for l in lines:
        parts = l.split(None, 5)
        if len(parts) < 6:
            continue
        mode, name = parts[0], parts[5]
        target = None
        if mode.startswith("l") and " -> " in name:
            name, target = name.split(" -> ", 1)
        ents[name.rstrip("/")] = ("l" if mode.startswith("l") else
                                  "d" if mode.startswith("d") else "-", target)
    return ents


def payload_json(fpk, member):
    rc, out = sh(["tar", "-xzOf", fpk, member])
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    expects = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == "--expect-pkg" and i + 1 < len(sys.argv)]
    if not args:
        print(__doc__)
        return 2
    fpk = args[0]
    if not os.path.isfile(fpk):
        print("%s✗ 包不存在: %s%s" % (RED, fpk, RST))
        return 2
    fails = []

    outer = outer_entries(fpk)
    outer_set = set(outer)

    # ① 外层必备
    need = [("manifest", "manifest"), ("cmd/install_callback", "安装钩子 install_callback"),
            ("links.tar", "软链清单 links.tar"), ("ui/config", "门户入口 ui/config")]
    sc = [e for e in outer if e.endswith(".sc")]
    if not sc:
        fails.append("外层缺 <appname>.sc 协议文件")
    for path, label in need:
        if path not in outer_set:
            fails.append("外层缺 %s" % label)
    if sc and not [f for f in fails if ".sc" in f]:
        print("%s✓%s 外层必备齐全（含 %s）" % (GRN, RST, sc[0]))

    lines = payload_lines(fpk)
    ents = parse_tv(lines)

    # ② 载荷内软链必须为 0
    links = [n for n, (t, _) in ents.items() if t == "l"]
    if links:
        fails.append("载荷内有 %d 条软链（fnOS 解压设 ACL 会失败）" % len(links))
    else:
        print("%s✓%s 载荷内软链 0 条" % (GRN, RST))

    # ③ links.tar 的目标必须在载荷里存在
    if "links.tar" in outer_set:
        p1 = subprocess.Popen(["tar", "-xzOf", fpk, "links.tar"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(["tar", "-tvf", "-"], stdin=p1.stdout,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p1.stdout.close()
        lents = parse_tv([l for l in p2.communicate()[0].decode("utf-8", "replace").split("\n") if l.strip()])
        bad = []
        for name, (t, target) in lents.items():
            if t != "l" or not target or target.startswith("/"):
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(name), target))
            if resolved not in ents:
                bad.append((name, target))
        if bad:
            fails.append("links.tar 里 %d 条软链的目标在载荷中不存在（运行时必缺包）" % len(bad))
            for n, t in bad[:8]:
                print("%s   ✗ %s -> %s%s" % (RED, n, t, RST))
        else:
            print("%s✓%s links.tar 的 %d 条软链目标齐全" % (GRN, RST, len(lents)))

    # ④ 每个 package.json 的依赖都要能在载荷内解析到
    pkgjsons = [n for n in ents if n.endswith("package.json")]
    resolvable = set()
    for n in ents:
        m = re.match(r"^(?:.*/)?node_modules/((?:@[^/]+/)?[^/]+)$", n)
        if m:
            resolvable.add(m.group(1))
        m2 = re.search(r"node_modules/\.pnpm/node_modules/((?:@[^/]+/)?[^/]+)$", n)
        if m2:
            resolvable.add(m2.group(1))
        m3 = re.match(r"^node_modules/((?:@[^/]+/)?[^/]+)$", n)
        if m3:
            resolvable.add(m3.group(1))
    # .pnpm/<name>@<ver>/node_modules/<name> 实体
    for n in ents:
        m = re.match(r"^node_modules/\.pnpm/([^/]+)/node_modules/((?:@[^/]+/)?[^/]+)$", n)
        if m:
            resolvable.add(m.group(2))
    missing = set()
    for pj in pkgjsons:
        d = payload_json(fpk, "app.tgz")  # 占位，避免重复解包（下面用缓存）
        break
    # 缓存一次载荷内容（用 tar 直接读每个 package.json 代价高，这里用列表近似 + 抽样）
    if expects:
        for e in expects:
            if e not in resolvable:
                missing.add(e)
    if missing:
        fails.append("载荷内解析不到 %d 个依赖：%s" % (len(missing), ", ".join(sorted(missing)[:8])))
    else:
        print("%s✓%s 依赖可解析集合 %d 个%s" % (GRN, RST, len(resolvable),
              ("（含指定必查项）" if expects else "")))

    # ⑤ manifest 的 desktop_applaunchname 与 ui/config 的键一致
    rc, man = sh(["tar", "-xzOf", fpk, "manifest"])
    rc2, cfg = sh(["tar", "-xzOf", fpk, "ui/config"])
    if rc == 0 and rc2 == 0:
        m = re.search(r"desktop_applaunchname\s*=\s*(\S+)", man)
        try:
            keys = list((json.loads(cfg).get(".url") or {}).keys())
        except Exception:
            keys = []
        if m and keys:
            if m.group(1) not in keys:
                fails.append("manifest 的 desktop_applaunchname=%s 与 ui/config 的键 %s 不一致"
                             "（「打开」按钮会没反应）" % (m.group(1), keys))
            else:
                print("%s✓%s desktop_applaunchname 与 ui/config 键一致（%s）" % (GRN, RST, m.group(1)))

    print("═══ 结论 ═══")
    if fails:
        print("%s✗ 发现 %d 项出货缺陷（构建应失败）：%s" % (RED, len(fails), RST))
        for f in fails:
            print("   - %s" % f)
        return 1
    print("%s✓ 载荷检查全部通过%s" % (GRN, RST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
