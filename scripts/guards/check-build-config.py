#!/usr/bin/env python3
"""check-build-config.py — 断言 build/config/build-config.yaml 的端口段是【映射】（不是标量）

【为什么需要】（属真实隐患，不是理论风险）
端口段的读取方全部按【对象】取值，例如：

    sec = cfg.get('spk') or {}          # 端口段读取方（打包脚本、远端安装脚本）
    proxy = sec.get('proxy_port') or …  # pack-spk.sh:60 / pack-fpk.sh:75 / build-npm-app.sh:47

若有人把段名写成标量（如 `spk: "30800"`），`sec` 就成了字符串，`sec.get(...)` 抛 AttributeError：
  · 在端口读取函数里那处 python 是"解析失败就不输出"的设计，
    于是上层只会看到「没读到端口段」—— **静默失效，极难定位**；
  · 在打包脚本里则可能直接失败。
故用本守卫把这种写法挡在 CI，而不是等运行时静默失效。

（对照：`install-config.json` 的 `spk`/`fpk` 键**没有**读取方，写什么都无害 —— 别把两者混为一谈，
  这里守的是 **build-config.yaml**。）

【判定方式】优先精确、且**不依赖 PyYAML**（本机 DSM 与 CI 都没有装）：
  1) 无 PyYAML：结构化检查 —— 段名行必须是 `spk:`（冒号后除注释外为空，即**没有内联值**），
     且其后首个非空、非注释行必须**缩进**（证明是块映射；若是标量，值会内联在冒号后）。
  2) 有 PyYAML：追加 `yaml.safe_load` 后 `isinstance(dict)` 的精确断言（双保险）。

用法：python3 scripts/guards/check-build-config.py [--file <path>] [--list]
退出码：0 通过 / 1 违规
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_FILE = os.path.join(ROOT, "build", "config", "build-config.yaml")

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


# 架构专属标记：build-excludes.json 由 x86_64 与 armv8 两次构建共用，
#   一旦写进这些词，就等于把另一个架构包自己需要的二进制裁掉（曾真实发生过）。
ARCH_SPECIFIC = ("linux-x64", "linux-arm64", "linux-armv7", "armv8", "aarch64", "x86_64")


def check_whitelist_arch_neutral():
    """裁剪白名单里的平台专属条目必须是 {arch} 占位，不能写死某个架构。

    为什么：纯白名单模式下，写死 linux-x64 会让 arm64 构建把自己需要的原生包整批删掉
    （实测 arm64 镜像起不来：Cannot find module ...linux-arm64-gnu）。
    """
    path = os.path.join(ROOT, "build", "config", "build-prune-whitelist.json")
    if not os.path.isfile(path):
        return []
    import json
    problems = []
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    for key in ("extra", "lockfileDeps", "_autoLearned"):
        for entry in data.get(key) or []:
            if not isinstance(entry, str):
                continue
            if "-linux-x64" in entry or "-linuxmusl-x64" in entry or "-linux-arm64" in entry:
                problems.append("build/config/build-prune-whitelist.json 的 %s 里 %r 写死了架构（应改 {arch}）"
                                % (key, entry))
    return problems


def check_platform_registry():
    """CI 平台注册表必须自洽：每条有 build 命令、runner、产物声明；name 唯一。

    为什么需要：build.yml 的 matrix 完全由 build/config/platforms.json 展开 ——
    注册表写错（漏 build、重名、产物 glob 拼错）会表现为「CI 里某个平台静默不出包」，
    而 workflow 本身语法完全合法，很难看出问题。
    """
    path = os.path.join(ROOT, "build", "config", "platforms.json")
    if not os.path.isfile(path):
        return []
    import json
    problems = []
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    platforms = data.get("platforms") or []
    if not platforms:
        return ["build/config/platforms.json 里没有任何平台"]
    seen = set()
    for entry in platforms:
        name = entry.get("name") or ""
        if not name:
            problems.append("build/config/platforms.json 有一条平台缺少 name")
            continue
        if name in seen:
            problems.append("build/config/platforms.json 平台重名：%s" % name)
        seen.add(name)
        if not entry.get("build"):
            problems.append("平台 %s 缺少 build 命令" % name)
        if not (entry.get("runner") or {}).get("x86_64"):
            problems.append("平台 %s 缺少 runner.x86_64" % name)
        if entry.get("publish") not in ("release", "registry"):
            problems.append("平台 %s 的 publish 必须是 release 或 registry（当前 %r）"
                            % (name, entry.get("publish")))
        if entry.get("publish") == "release" and not (entry.get("artifacts") or []):
            problems.append("平台 %s 是 release 型但没有声明 artifacts" % name)
        if not (entry.get("watch") or []):
            problems.append("平台 %s 没有 watch 路径（变化检测会永远判为未变化）" % name)
    # target.watch 必须存在，否则「target 是否重建」无法判定
    if not ((data.get("target") or {}).get("watch") or []):
        problems.append("build/config/platforms.json 缺少 target.watch")
    return problems


def check_excludes_arch_neutral():
    path = os.path.join(ROOT, "build", "config", "build-excludes.json")
    if not os.path.isfile(path):
        return []
    problems = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            text = line.strip()
            if not text.startswith('"--exclude='):
                continue
            lowered = text.lower()
            for token in ARCH_SPECIFIC:
                if token in lowered:
                    problems.append("build/config/build-excludes.json:%d 含架构专属词 %r（共享文件，会打坏另一个架构的包）" % (number, token))
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description="断言 build-config.yaml 的端口段是映射")
    ap.add_argument("--file", default=DEFAULT_FILE, help="待检查的文件（默认 build/config/build-config.yaml）")
    ap.add_argument("--list", action="store_true", help="只打印被检查的段名后退出")
    args = ap.parse_args(argv)

    if args.list:
        print("\n".join(REQUIRED_SECTIONS))
        return 0

    if not os.path.isfile(args.file):
        sys.stderr.write("[!] 找不到配置文件: %s\n" % args.file)
        return 1

    bad, used_yaml = _check(args.file)
    bad = bad + check_excludes_arch_neutral()
    bad = bad + check_platform_registry()
    bad = bad + check_whitelist_arch_neutral()
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
