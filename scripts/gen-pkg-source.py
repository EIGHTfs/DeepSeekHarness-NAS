#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen-pkg-source.py — 把发布出来的 spk 生成群晖「套件来源」索引。

背景：
  手动下载 spk 装的包，DSM 无法比较版本，套件中心永远不提示新版本；
  只有「套件来源（package source）」里的包才会出现在「更新」页，也才谈得上自动更新。
  DSM 读的索引是一份 JSON：{"packages":[{package, dname, version, link, md5, size, ...}]}
  （字段名照 SynoCommunity 实际响应取，不是猜的）。

浏览型定位：
  本项目 INFO 版本取官方前三位（0.2.3），同一 patch 的多个预发布彼此版本号相同，
  DSM 无法据此判断「谁更新」。所以本索引只做「让套件中心发现并安装我们当前的包」，
  不承诺同 patch 内的升级判定；需要别的版本仍从 Release 页手动装。

  DSM 源在服务端按请求的 arch/build 过滤，静态托管做不到，所以按架构各出一份索引：
    index-x86_64.json / index-armv8.json —— 用户按自己 NAS 架构添加对应那个 URL。

用法：
  python3 scripts/gen-pkg-source.py --spk a.spk --spk b.spk --out-dir pkg-source
  python3 scripts/gen-pkg-source.py --spk x.spk --dry-run          # 只打印条目

注意：link 必须是 DSM 能直接下载 spk 的绝对 URL（Release 资产直链或自建静态地址）。
"""
from __future__ import print_function

import argparse
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile

# 索引里我们要产出的字段。字段名与 SynoCommunity 现网响应一致。
DISPLAY_NAME = "DeepSeekRuntime NAS"
DISTRIBUTOR = "DeepSeekHarness-NAS"
DISTRIBUTOR_URL = "https://github.com/EIGHTfs/DeepSeekHarness-NAS"
MAINTAINER = "EIGHTfs"
MAINTAINER_URL = "https://github.com/EIGHTfs"
DESC = "在群晖上以套件方式运行 DeepSeekRuntime（DSH）Web 版：自带 node、预编译产物、反代与门户免密入口。"


def read_info_from_spk(path):
    """从 spk 外层 tar 里读 INFO 字段（INFO 是纯文本 key=value）。"""
    info = {}
    try:
        with tarfile.open(path, "r:") as outer:
            member = None
            for candidate in outer.getmembers():
                if candidate.name.lstrip("./") == "INFO":
                    member = candidate
                    break
            if member is None:
                return None, "spk 内找不到 INFO"
            raw = outer.extractfile(member).read().decode("utf-8", "replace")
    except Exception as exc:
        return None, "读 spk 失败：%s" % exc

    for line in raw.splitlines():
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        info[key.strip()] = value.strip().strip('"')
    return info, None


def md5_of(path, chunk_bytes=4 * 1024 * 1024):
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_bytes)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def build_entry(spk_path, link):
    info, err = read_info_from_spk(spk_path)
    if info is None:
        return None, err
    package = info.get("package")
    version = info.get("version")
    arch = info.get("arch")
    if not package or not version or not arch:
        return None, "INFO 缺 package/version/arch 字段"
    entry = {
        "package": package,
        "dname": info.get("displayname") or DISPLAY_NAME,
        "desc": DESC,
        # 版本必须与 spk 内 INFO 完全一致，否则 DSM 会认为索引与包不匹配
        "version": version,
        "link": link,
        "md5": md5_of(spk_path),
        "size": os.path.getsize(spk_path),
        "distributor": DISTRIBUTOR,
        "distributor_url": DISTRIBUTOR_URL,
        "maintainer": MAINTAINER,
        "maintainer_url": MAINTAINER_URL,
        "changelog": info.get("changelog") or "",
        "qinst": False,
        "qstart": False,
        "qupgrade": False,
        "startable": "yes",
    }
    return entry, arch


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--spk", action="append", default=[], help="spk 路径，可重复给多个（不同架构）")
    ap.add_argument("--out-dir", default="pkg-source", help="索引输出目录（缺省 pkg-source）")
    ap.add_argument("--base-url", default="", help="link 前缀；缺省用 <仓库 releases 直链模板> 需自行改")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    args = ap.parse_args()

    if not args.spk:
        print("✗ 至少给一个 --spk", file=sys.stderr)
        return 2

    by_arch = {}
    for path in args.spk:
        if not os.path.isfile(path):
            print("✗ 文件不存在：%s" % path, file=sys.stderr)
            return 2
        link = args.base_url.rstrip("/") + "/" + os.path.basename(path) if args.base_url else os.path.basename(path)
        entry, arch = build_entry(path, link)
        if entry is None:
            print("✗ %s：%s" % (path, arch), file=sys.stderr)
            return 1
        by_arch.setdefault(arch, []).append(entry)

    if args.dry_run:
        for arch, entries in sorted(by_arch.items()):
            print("═══ arch=%s ═══" % arch)
            for e in entries:
                print(json.dumps(e, ensure_ascii=False, indent=2))
        return 0

    os.makedirs(args.out_dir, exist_ok=True)
    written = []
    for arch, entries in sorted(by_arch.items()):
        target = os.path.join(args.out_dir, "index-%s.json" % arch)
        payload = {"packages": entries}
        with io.open(target, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        written.append((target, len(entries)))

    for target, count in written:
        print("✓ %s（%d 条）" % (target, count))
    print("")
    print("下一步：把 %s/ 目录发布到可访问的静态地址，"
          "在 DSM 套件中心 → 设置 → 套件来源 里按架构添加对应 index-<arch>.json 的 URL。" % args.out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
