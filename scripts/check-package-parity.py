#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-package-parity.py —— 拿「安装成功过的包」当基准，比对另一个包的结构差异。

用法:
    ./scripts/check-package-parity.py <基准包> <候选包> [--verbose]
    ./scripts/check-package-parity.py <基准包> <候选包> --baseline-self   # 只体检基准包
支持 .fpk（飞牛 fnOS）与 .spk（群晖），自动识别；纯只读，不解包到磁盘。

为什么需要它（每一条都对应 2026-10-09 实际踩过的坑）：
  · 少一个 cmd 钩子（install_callback）→ fnOS 安装钩子不执行 → 权限/数据目录建不出来
  · FPK 载荷里留着软链 → fnOS 解压逐条目设 ACL → acl_get_file failed
    （前端「设置目录权限失败」）
  · 载荷里存在【悬空软链】（目标实体被裁剪删掉）→ 运行时 Cannot find package 'x'
    → DSH 内置插件 failed to import / tool-schedule never started / 新建会话失败
  · 外层少了 .sc / manifest / links.tar → 门户打不开或安装期无法还原软链

判定口径：**基准包有的，候选包不能少**（缺失即回归，退出码 1）；
          候选包多出来的只提示不判错（新版本会新增文件）；
          FPK 载荷里出现软链一律判错（fnOS 上必炸）。
"""
import io
import os
import subprocess
import sys

RED = "\033[31m" if sys.stdout.isatty() else ""
GRN = "\033[32m" if sys.stdout.isatty() else ""
YLW = "\033[33m" if sys.stdout.isatty() else ""
RST = "\033[0m" if sys.stdout.isatty() else ""


def _no_slash(paths):
    """剥掉条目结尾斜杠。

    ★ 2026-10-10 实测：tar 会把【目录】条目记成带结尾斜杠的形式（如
      ./node_modules/.pnpm/fast-check@4.8.0/node_modules/fast-check/），
      而软链指向的是不带斜杠的路径 → 精确匹配失败 → 把【能正常工作的官方基准包】
      也误判成 5638 条悬空（反向自检证实：基准当候选时同样报 5638）。
      统一剥掉结尾斜杠，悬空判定才可信。
    """
    out = set()
    for p in paths:
        p = p.rstrip("/")
        while p.startswith("./"):
            p = p[2:]
        out.add(p)
    return out


def sh(cmd):
    """跑命令，返回 (rc, stdout 文本)。只读操作，失败不抛。"""
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def pkg_kind(path):
    """识别 fpk / spk：fpk 外层是 gzip（tar -tzf），spk 外层是未压缩 tar（tar -tf）。"""
    rc, _ = sh(["tar", "-tzf", path])
    if rc == 0:
        return "fpk"
    rc, _ = sh(["tar", "-tf", path])
    if rc == 0:
        return "spk"
    return None


def outer_entries(path, kind):
    """外层条目清单（fpk 用 z，spk 不用）。"""
    flag = "-tzf" if kind == "fpk" else "-tf"
    rc, out = sh(["tar", flag, path])
    if rc != 0:
        return []
    return [l for l in out.split("\n") if l.strip()]


def payload_name(kind):
    return "app.tgz" if kind == "fpk" else "package.tgz"


def payload_listing(path, kind):
    """载荷（fpk: app.tgz / spk: package.tgz）内的条目，返回 tar -tvzf 的原始行。

    用 tar -xzOf 把内层流出来再 tar -tvzf 读，全程不落盘。
    """
    member = payload_name(kind)
    flag = "-xzOf" if kind == "fpk" else "-xOf"
    p1 = subprocess.Popen(["tar", flag, path, member], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(["tar", "-tvzf", "-"], stdin=p1.stdout,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p1.stdout.close()
    out = p2.communicate()[0].decode("utf-8", "replace")
    return [l for l in out.split("\n") if l.strip()]


def parse_tv(lines):
    """把 tar -tvzf 行拆成 {路径: ('l'|'d'|'-', 目标或None)}。

    tar -tv 的列：权限 属主/组 大小 日期 时间 名字 [-> 目标]
    名字里可能有空格 → 用「权限段 + 从第 6 列起」的方式取名字，链接目标按 ' -> ' 切。
    """
    ents = {}
    for l in lines:
        parts = l.split(None, 5)
        if len(parts) < 6:
            continue
        mode, name = parts[0], parts[5]
        target = None
        if mode.startswith("l") and " -> " in name:
            name, target = name.split(" -> ", 1)
        if mode.startswith("l"):
            t = "l"
        elif mode.startswith("d"):
            t = "d"
        else:
            t = "-"
        ents[name.rstrip("/")] = (t, target)
    return ents


def dangling(ents):
    """找出悬空软链：链接目标（相对链接所在目录解析）在载荷里不存在。"""
    bad = []
    for name, (t, target) in ents.items():
        if t != "l" or not target:
            continue
        if target.startswith("/"):
            continue  # 绝对链接不判断（跨包/系统路径）
        base = os.path.dirname(name)
        resolved = os.path.normpath(os.path.join(base, target))
        if resolved not in ents:
            bad.append((name, target))
    return bad


def manifest_fields(path, kind):
    """读外层 manifest 的字段名集合（只读字段名，不打印值）。"""
    flag = "-xzOf" if kind == "fpk" else "-xOf"
    rc, out = sh(["tar", flag, path, "manifest"])
    if rc != 0:
        return set()
    fields = set()
    for l in out.split("\n"):
        if "=" in l and not l.strip().startswith("#"):
            fields.add(l.split("=", 1)[0].strip())
    return fields


def links_tar_dangling(path, kind, outer, ents):
    """体检 links.tar 里记录的软链：目标在【载荷】里是否存在。

    这是最要命的一项 —— FPK 载荷里的软链已被后处理删掉，真正会悬空的是
    links.tar 里那些（目标实体被裁剪删掉）。实测症状：
      .pnpm/execa@*/node_modules/is-plain-obj 的目标不存在
      → 运行时 Cannot find package 'is-plain-obj' / 'jsbi'
      → DSH 内置插件 failed to import / tool-schedule never started / 新建会话失败。
    """
    if "links.tar" not in outer:
        return []
    flag = "-xzOf" if kind == "fpk" else "-xOf"
    p1 = subprocess.Popen(["tar", flag, path, "links.tar"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(["tar", "-tvf", "-"], stdin=p1.stdout,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p1.stdout.close()
    out = p2.communicate()[0].decode("utf-8", "replace")
    lents = parse_tv([l for l in out.split("\n") if l.strip()])
    bad = []
    for name, (t, target) in lents.items():
        if t != "l" or not target or target.startswith("/"):
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(name), target))
        if resolved not in ents:
            bad.append((name, target))
    return bad


def links_txt_dangling(path, kind, outer, ents):
    """体检 links.txt（旧法文本清单，path<TAB>target）里软链目标是否存在。

    历史形态：2026-10-09 之前打包产出 links.txt，安装期逐行 ln -s 还原。
    该形态同样会因为裁剪删掉目标实体而悬空 —— 守卫两种形态都要能抓。
    """
    if "links.txt" not in outer:
        return []
    flag = "-xzOf" if kind == "fpk" else "-xOf"
    rc, out = sh(["tar", flag, path, "links.txt"])
    if rc != 0:
        return []
    bad = []
    for line in out.split("\n"):
        if not line.strip() or "\t" not in line:
            continue
        name, target = line.split("\t", 1)
        name, target = name.strip(), target.strip()
        if not name or not target or target.startswith("/"):
            continue
        if name.startswith("./"):
            name = name[2:]
        resolved = os.path.normpath(os.path.join(os.path.dirname(name), target))
        if resolved not in ents:
            bad.append((name, target))
    return bad


def inspect(path, verbose=False):
    """体检单个包，返回 dict。"""
    kind = pkg_kind(path)
    if kind is None:
        print("%s✗ 无法识别的包（既不是 gzip tar 也不是 tar）: %s%s" % (RED, path, RST))
        return None
    outer = outer_entries(path, kind)
    lines = payload_listing(path, kind)
    ents = parse_tv(lines)
    links = [n for n, (t, _) in ents.items() if t == "l"]
    bad = dangling(ents)
    hooks = sorted(e for e in outer if e.startswith("cmd/") and e.count("/") == 1)
    tops = sorted({e.split("/")[0] for e in ents if e})
    info = {
        "path": path, "kind": kind, "outer": _no_slash(outer), "outer_set": set(outer),
        "ents": _no_slash(ents), "links": links, "dangling": bad, "hooks": hooks,
        "tops": tops, "manifest": manifest_fields(path, kind),
        "has_sc": any(e.endswith(".sc") for e in outer),
        "has_manifest": "manifest" in outer,
        "has_links_tar": "links.tar" in outer,
        "has_links_txt": "links.txt" in outer,
        "has_install_callback": "cmd/install_callback" in outer,
    }
    if verbose:
        print("  [%s] %s" % (kind, os.path.basename(path)))
        print("     外层条目 %d，载荷条目 %d，软链 %d，悬空软链 %d"
              % (len(outer), len(ents), len(links), len(bad)))
    return info


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    verbose = "--verbose" in sys.argv
    selfcheck = "--baseline-self" in sys.argv
    if len(args) < 1 or (len(args) < 2 and not selfcheck):
        print(__doc__)
        return 2

    base = inspect(args[0], verbose)
    if base is None:
        return 2
    if selfcheck:
        cand = base
    else:
        cand = inspect(args[1], verbose)
        if cand is None:
            return 2

    errs = []
    warns = []

    print("═══ 基准: %s（%s）" % (os.path.basename(base["path"]), base["kind"]))
    if not selfcheck:
        print("═══ 候选: %s（%s）" % (os.path.basename(cand["path"]), cand["kind"]))

    # ① 外层条目：基准有的候选不能少
    missing = sorted(base["outer_set"] - cand["outer_set"])
    extra = sorted(cand["outer_set"] - base["outer_set"])
    if missing:
        errs.append("外层少了 %d 个条目（基准有、候选无）" % len(missing))
        print("%s✗ 外层缺失:%s" % (RED, RST))
        for m in missing[:20]:
            print("     - %s" % m)
        if len(missing) > 20:
            print("     …（共 %d 个）" % len(missing))
    if extra:
        warns.append("外层多了 %d 个条目（候选新增，通常正常）" % len(extra))
        print("%s· 外层新增 %d 个（前 10）:%s" % (YLW, len(extra), RST))
        for e in extra[:10]:
            print("     + %s" % e)

    # ② 关键文件
    for key, label in (("has_sc", "外层 .sc 协议文件"),
                       ("has_manifest", "外层 manifest"),
                       ("has_install_callback", "cmd/install_callback 钩子")):
        if base[key] and not cand[key]:
            errs.append("候选缺 %s" % label)
            print("%s✗ 候选缺 %s%s" % (RED, label, RST))
        elif cand[key]:
            print("%s✓ %s 存在%s" % (GRN, label, RST))

    # ③ 载荷软链（FPK 必须 0）
    if cand["kind"] == "fpk" and cand["links"]:
        errs.append("FPK 载荷里有 %d 条软链（fnOS 解压设 ACL 会失败）" % len(cand["links"]))
        print("%s✗ FPK 载荷含 %d 条软链（必须 0；后处理没生效？）%s"
              % (RED, len(cand["links"]), RST))
    elif cand["kind"] == "fpk":
        print("%s✓ FPK 载荷软链 0 条%s" % (GRN, RST))

    # ④ 悬空软链（运行时 Cannot find package 的根源）
    if cand["dangling"]:
        # ★ 2026-10-10 用户口径（真机验证）：SPK 载荷里的悬空软链【不影响安装可用】——
        #   群晖原样解软链、dev/可选包本就不需要、运行期还有 start.sh 自愈兜底。
        #   实测官方基准 2.0 SPK 自身也有 5638 条同形态链且工作正常。
        #   → 降级为【提示】，不再判回归；硬判据只留外层结构 / 钩子 / manifest。
        print("%s· 提示：载荷有 %d 条悬空软链（不做硬判据；SPK 实测可正常安装运行）%s"
              % (YLW, len(cand["dangling"]), RST))
        print("%s✗ 悬空软链 %d 条（前 15；这就是插件 failed to import 的根源）:%s"
              % (RED, len(cand["dangling"]), RST))
        for n, t in cand["dangling"][:15]:
            print("     %s -> %s" % (n, t))
        if len(cand["dangling"]) > 15:
            print("     …（共 %d 条）" % len(cand["dangling"]))
    else:
        print("%s✓ 载荷内无悬空软链%s" % (GRN, RST))

    # ④b links.tar 里的软链目标是否存在（★ 最关键：载荷已无软链，悬空全在这里）
    lt_bad = links_tar_dangling(cand["path"], cand["kind"], cand["outer"], cand["ents"])
    if lt_bad:
        errs.append("links.tar 里 %d 条软链的目标在载荷中不存在（运行时必缺包）" % len(lt_bad))
        print("%s✗ links.tar 悬空 %d 条（前 15；运行时 Cannot find package 的根源）:%s"
              % (RED, len(lt_bad), RST))
        for n, t in lt_bad[:15]:
            print("     %s -> %s" % (n, t))
        if len(lt_bad) > 15:
            print("     …（共 %d 条）" % len(lt_bad))
    elif cand["has_links_tar"]:
        print("%s✓ links.tar 内软链目标齐全%s" % (GRN, RST))

    # ④c links.txt（旧法）同样体检
    lt_txt = links_txt_dangling(cand["path"], cand["kind"], cand["outer"], cand["ents"])
    if lt_txt:
        errs.append("links.txt 里 %d 条软链的目标在载荷中不存在（运行时必缺包）" % len(lt_txt))
        print("%s✗ links.txt 悬空 %d 条（前 15）:%s" % (RED, len(lt_txt), RST))
        for n, t in lt_txt[:15]:
            print("     %s -> %s" % (n, t))
        if len(lt_txt) > 15:
            print("     …（共 %d 条）" % len(lt_txt))
    elif cand["has_links_txt"]:
        print("%s✓ links.txt 内软链目标齐全%s" % (GRN, RST))

    # ⑤ 钩子集合
    hmiss = sorted(set(base["hooks"]) - set(cand["hooks"]))
    if hmiss:
        errs.append("cmd 钩子少了 %s" % ", ".join(hmiss))
        print("%s✗ cmd 钩子缺失: %s%s" % (RED, ", ".join(hmiss), RST))
    else:
        print("%s✓ cmd 钩子 %d 个，与基准一致%s" % (GRN, len(cand["hooks"]), RST))

    # ⑥ manifest 字段
    fmiss = sorted(base["manifest"] - cand["manifest"])
    if fmiss:
        warns.append("manifest 少了字段 %s" % ", ".join(fmiss))
        print("%s· manifest 少字段: %s%s" % (YLW, ", ".join(fmiss), RST))

    # ⑦ 软链清单机制
    if base["has_links_tar"] and not cand["has_links_tar"]:
        errs.append("候选缺 links.tar（安装期无法精确还原软链）")
        print("%s✗ 候选缺 links.tar%s" % (RED, RST))

    print("═══ 结论 ═══")
    if errs:
        print("%s✗ 发现 %d 项回归（基准有、候选缺 / 或候选有硬伤）:%s" % (RED, len(errs), RST))
        for e in errs:
            print("   - %s" % e)
        for w in warns:
            print("%s   · %s%s" % (YLW, w, RST))
        return 1
    print("%s✓ 候选包与基准结构一致，未发现回归%s" % (GRN, RST))
    for w in warns:
        print("%s   · %s%s" % (YLW, w, RST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
