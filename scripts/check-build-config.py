#!/usr/bin/env python3
"""check-build-config.py — 断言 build/build-config.yaml 的端口段是【映射】（不是标量）

【为什么需要】（2026-10-05 发现，属真实隐患）
端口段的读取方全部按【对象】取值，例如：

    sec = cfg.get('spk') or {}          # install-remote-spk.sh / install-remote-fpk.sh
    proxy = sec.get('proxy_port') or …  # pack-spk.sh:60 / pack-fpk.sh:75 / build-npm-app.sh:47

若有人把段名写成标量（如 `spk: "30800"`），`sec` 就成了字符串，`sec.get(...)` 抛 AttributeError：
  · 在 `read_ports()`（install-remote-spk.sh:47）里那处 python 是"解析失败就不输出"的设计，
    于是上层只会看到「没读到端口段」—— **静默失效，极难定位**；
  · 在打包脚本里则可能直接失败。
故用本守卫把这种写法挡在 CI，而不是等运行时静默失效。

（对照：`install-config.json` 的 `spk`/`fpk` 键**没有**读取方，写什么都无害 —— 别把两者混为一谈，
  这里守的是 **build-config.yaml**。）

【判定方式】优先精确、且**不依赖 PyYAML**（本机 DSM 与 CI 都没有装）：
  1) 无 PyYAML：结构化检查 —— 段名行必须是 `spk:`（冒号后除注释外为空，即**没有内联值**），
     且其后首个非空、非注释行必须**缩进**（证明是块映射；若是标量，值会内联在冒号后）。
  2) 有 PyYAML：追加 `yaml.safe_load` 后 `isinstance(dict)` 的精确断言（双保险）。

用法：python3 scripts/check-build-config.py [--file <path>] [--list]
退出码：0 通过 / 1 违规
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FILE = os.path.join(ROOT, "build", "build-config.yaml")

# 必须为映射的端口段（与 README「build-config.yaml（端口权威配置）」一致）
REQUIRED_SECTIONS = ("defaults", "spk", "fpk")

# 顶层段名行：行首无缩进、`名字:`，冒号后只允许空白或注释
SECTION_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(#.*)?$")
# 顶层【带内联值】的行：`spk: "30800"` / `spk: 30800`
INLINE_VALUE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*\S")


def _lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def _next_meaningful(lines, start):
    """返回 start 之后首个非空、非注释行（保持原文），没有则返回 None。"""
    for ln in lines[start:]:
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        return ln
    return None


def _check(path):
    """返回违规列表（空列表 = 通过）。"""
    bad = []
    lines = _lines(path)

    inline = {}
    for i, ln in enumerate(lines, 1):
        m = INLINE_VALUE_RE.match(ln)
        if m and not ln.startswith((" ", "\t")):
            inline[m.group(1)] = (i, ln.rstrip())

    for sec in REQUIRED_SECTIONS:
        # ① 段名是否存在，且没有内联值
        idx = None
        for i, ln in enumerate(lines):
            m = SECTION_RE.match(ln)
            if m and m.group(1) == sec:
                idx = i
                break
        if idx is None:
            if sec in inline:
                n, text = inline[sec]
                bad.append(
                    "build-config.yaml:%d  `%s` 是【内联标量】而非映射：%s\n"
                    "      → 读取方 sec.get('proxy_port') 会抛 AttributeError（read_ports 里表现为"
                    "「静默读不到端口段」）" % (n, sec, text.strip())
                )
            else:
                bad.append("build-config.yaml 缺少必需的端口段 `%s:`" % sec)
            continue

        # ② 段后首个有效行必须缩进（块映射）；否则说明段是空的或写法异常
        nxt = _next_meaningful(lines, idx + 1)
        if nxt is None:
            bad.append("build-config.yaml 的 `%s:` 段是空的（需要 proxy_port 等子键）" % sec)
        elif not nxt.startswith((" ", "\t")):
            bad.append(
                "build-config.yaml 的 `%s:` 段后紧跟非缩进行 `%s`\n"
                "      → 该段不是块映射（可能是标量或与下一段粘连）" % (sec, nxt.strip())
            )

    # ③ 有 PyYAML 时再做一次精确断言（双保险；无 PyYAML 也照样能跑上面的结构化检查）
    try:
        import yaml  # noqa: F401
    except ImportError:
        return bad, False
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        for sec in REQUIRED_SECTIONS:
            v = (doc or {}).get(sec)
            if not isinstance(v, dict):
                bad.append(
                    "build-config.yaml 的 `%s` 解析后类型是 %s，必须是映射（dict）"
                    % (sec, type(v).__name__)
                )
    except Exception as e:  # 解析失败本身就是违规（读取方也读不了）
        bad.append("build-config.yaml 无法解析: %s" % e)
    return bad, True


def main(argv=None):
    ap = argparse.ArgumentParser(description="断言 build-config.yaml 的端口段是映射")
    ap.add_argument("--file", default=DEFAULT_FILE, help="待检查的文件（默认 build/build-config.yaml）")
    ap.add_argument("--list", action="store_true", help="只打印被检查的段名后退出")
    args = ap.parse_args(argv)

    if args.list:
        print("\n".join(REQUIRED_SECTIONS))
        return 0

    if not os.path.isfile(args.file):
        sys.stderr.write("[!] 找不到配置文件: %s\n" % args.file)
        return 1

    bad, used_yaml = _check(args.file)
    if bad:
        sys.stderr.write("✗ build-config 守卫失败（%d 项）：\n" % len(bad))
        for b in bad:
            sys.stderr.write("   - %s\n" % b)
        return 1

    print("✓ build-config 守卫通过（%s 均为映射%s）"
          % (" / ".join(REQUIRED_SECTIONS), "，PyYAML 精确断言已启用" if used_yaml else "，结构化检查"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
