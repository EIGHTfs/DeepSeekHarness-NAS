#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pkg-source.py — 把任意 GitHub 仓库的 Release 变成 DSM 套件源（单文件，仅 python3 标准库）。

零耦合的三条约束（与首版一致，改动不破坏）：
  1. 不 import 任何项目代码、不读任何项目文件 —— 拷到任意目录、任意机器都能直接跑；
  2. 不假设任何仓库的产物命名 —— 资产匹配、架构归类、包名全部由参数决定；
  3. spk 的下载由**套件中心**完成 —— 本工具不下载整包。

与首版的区别（为什么改）：
  首版把 package/version/arch 全从**文件名正则**里猜，实测有两个真问题：
    · 命名里版本段带点的（如 redis_cedarview_2.6.7-2.spk）整条正则不匹配，且被静默丢弃；
    · 架构组 [A-Za-z0-9_]+ 会把日期吃进架构名（couchpotatoserver_noarch_20130412-3.spk
      被解析成 arch=noarch_20130412、version=3），挂到套件中心上版本比较必然错乱。
  现改为：**元数据以 SPK 内 INFO 为权威**，文件名只用于初筛。DSM 7 判断「能否静默升级」
  依赖的 silent_upgrade / auto_upgrade_from 就在 INFO 里，首版读不到，等于自动更新那一环是断的。

只读包头、不下整包：
  实测本仓库的 spk 是纯 tar，INFO 是第一个成员、775 字节，前 8KB 就能读完。
  故用 HTTP Range 只取前 --header-bytes（默认 64KB），用 tarfile 逐个 next() 读到 INFO 即停。
  注意必须用 next() 而不能用 getnames()：后者会遍历到数据末尾，对截断的包头必然抛 ReadError。

基本用法
  python3 pkg-source.py --repo owner/repo --port 8899
  python3 pkg-source.py --repo EIGHTfs/DeepSeekHarness-NAS --check
  python3 pkg-source.py --repo EIGHTfs/DeepSeekHarness-NAS --releases 5 --check
  python3 pkg-source.py --from-spk-dir ./release --base-url http://10.0.0.9:8899 --check

环境变量
  GH_TOKEN / GITHUB_TOKEN   访问 GitHub API 的令牌（匿名 60 次/小时，建议给）
"""
from __future__ import print_function

import argparse
import hashlib
import io
import json
import os
import re
import socket
import sys
import tarfile
import threading
import time
import urllib.parse
import urllib.request
import zlib

# 资产名初筛正则：只用来判断「这个资产像不像 spk」并兜底取架构，元数据以 INFO 为准。
# 注意它无法覆盖所有历史命名：`包_架构_版本.构建.spk`（架构与版本用下划线连着）与
# `包_架构-版本.spk`（架构本身含下划线，如 x86_64）在正则层面是歧义的。故另有
# FALLBACK_ASSET_REGEX 兜底：只要确认是 .spk，包名取首个分隔符前的一段，架构与版本交给 INFO。
DEFAULT_ASSET_REGEX = r"(?P<package>[^_/]+)_(?P<arch>[A-Za-z0-9_]+)-(?P<version>[0-9][\w.\-]*)\.spk$"
FALLBACK_ASSET_REGEX = re.compile(r"^(?P<package>[^_/]+)[_-].*\.spk$", re.I)
INDEX_NAME = re.compile(r"^index-([A-Za-z0-9_]+)\.json$")
# DSM 真正认的单文件目录名；对外的访问路径是 /api/package（见 make_handler）
CATALOG_NAME = "catalog.json"

# 架构代码族。DSM 拿**本机架构代码**去匹配 catalog 里的 arch 数组 —— 本机是 kvmx64、
# SA6400 是 epyc7002，只写 x86_64 会让包在这些机型上完全不显示。故默认把同族代码全列出。
# 格式 `族=代码,代码;族2=代码,代码`，可用 --arch-expand 覆盖或增补。
DEFAULT_ARCH_EXPAND = (
    "x86_64=x86_64,x64,x86,kvmx64,epyc7002;"
    "armv8=armv8,armada38x,rtd1296,alpine,alpine4k,monaco,rtd1619,rtd1619b"
)

# 本地包 md5 缓存：(路径, mtime, 大小) → 摘要。170MB 的包每次刷新重算太浪费，
# 文件没变就直接复用。
MD5_CACHE = {}

# 读取包头的范围阶梯：先用默认值，不够再放大一档（INFO 若不在包首则需要）。
DEFAULT_HEADER_BYTES = 65536
FALLBACK_HEADER_BYTES = 1048576

# 直连拿不到 release 资产时的镜像候选，按顺序尝试；直连由 main() 自动追加到最后兜底。
# 实测：本机直连 github release 资产无响应（走 objects.githubusercontent.com 被拦），
# 而 ghfast.top 前缀 + Range 返回 206 正常，故默认放镜像在前。
DEFAULT_MIRRORS = "https://ghfast.top/"

# 预发布标记的权重：同版本号下 alpha < beta < rc < 正式版。
PRERELEASE_RANK = {"dev": -2, "alpha": -1, "a": -1, "beta": 0, "b": 0, "rc": 1, "pre": -1}

# 资产名里常出现的架构别名 → 群晖架构名。DSM 按 arch 拉对应索引，写错就取不到包。
DEFAULT_ARCH_MAP = "aarch64=armv8,amd64=x86_64,x64=x86_64,arm64=armv8"


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


# 解析过程中值得让用户看到、但不足以丢弃该包的问题（架构未知、走兜底等）。
WARNINGS = []

# 仅在 --verbose 时输出的说明性信息。
# 典型是「资产名版本与 INFO 版本不同」——这不是缺陷：群晖规定 INFO 的 version 每段只允许
# 数字，预发布阶段被编码进 build 段（alpha 基数 1000 / rc 基数 3000 / 正式 9000，见
# docs/打包规范.md 3.1），资产名里的 alpha、rc 只是给人看的展示名。两者不同是设计意图，
# 默认不该刷日志，否则每跑一次都误报一遍。
VERBOSE_NOTES = []


# ---------------------------------------------------------------------------
# SPK 元数据解析
# ---------------------------------------------------------------------------
def parse_info_text(text):
    """解析 INFO：形如 key="value" 的无段落 ini。

    不用 configparser —— 它要求有 [section]，而群晖 INFO 是扁平 key=value。
    值里可能带转义引号，故只剥掉首尾一对引号，不碰内部内容。
    """
    meta = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue
        matched = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.*)$", stripped)
        if not matched:
            continue
        key = matched.group(1).lower()
        value = matched.group(2).strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        # INFO 的多行值用 \n 字面量表示，还原成真换行便于套件中心展示
        meta[key] = value.replace("\\n", "\n")
    return meta


def extract_metadata_from_tar_bytes(raw):
    """从（可能被截断的）tar 或 gzip tar 数据里取出 INFO 文本与包内图标。

    返回 (info_text 或 None, {"72": bytes, "256": bytes})。
    截断是正常情况——我们只买了前 64KB。INFO 是第一个成员，两个图标紧随其后
    （实测 2326 + 11141 字节），都在这个范围内；再往后是 conf/ 与实体文件，
    遇到截断抛错就停下，已取到的照常返回。
    """
    payload = raw
    if raw[:2] == b"\x1f\x8b":
        # gzip 包：Range 拿到的是压缩流前缀，用增量解压尽可能多吐数据
        try:
            payload = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw)
        except zlib.error:
            return None, {}
    try:
        archive = tarfile.open(fileobj=io.BytesIO(payload), mode="r:")
    except Exception:
        return None, {}

    # 包内图标成员名 → 输出尺寸标签
    icon_members = {"PACKAGE_ICON.PNG": "72", "PACKAGE_ICON_256.PNG": "256"}
    info_text = None
    icons = {}
    try:
        while True:
            member = archive.next()
            if member is None:
                break
            name = member.name.lstrip("./")
            if name in icon_members:
                handle = archive.extractfile(member)
                if handle is not None:
                    icons[icon_members[name]] = handle.read()
                continue
            if name != "INFO":
                continue
            handle = archive.extractfile(member)
            if handle is not None:
                info_text = handle.read().decode("utf-8", "replace")
            # 注意：不能在此 break —— 图标排在 INFO 之后，要继续取
            if len(icons) >= len(icon_members):
                break
    except Exception:
        # 包头在后续成员处断了，已取到的内容仍然有效
        pass
    finally:
        try:
            archive.close()
        except Exception:
            pass
    return info_text, icons


def save_icons(out_dir, package, icons):
    """把包头里取到的图标落盘，供 /icon/<包名>-<尺寸>.png 路由读取。"""
    if not icons:
        return
    icon_dir = os.path.join(out_dir, "icons")
    try:
        os.makedirs(icon_dir, exist_ok=True)
        for label, data in icons.items():
            path = os.path.join(icon_dir, "%s-%s.png" % (package, label))
            with open(path, "wb") as handle:
                handle.write(data)
    except OSError:
        # 图标只是展示用，写不进去不影响目录可用性
        pass


def fetch_prefix(url, size, mirrors):
    """用 Range 只取前 size 字节，返回 bytes。

    服务器若忽略 Range 而返回 200 整包，这里只 read(size) 就断开，
    避免为了读 775 字节的 INFO 拖下 170MB。
    """
    last_error = None
    for prefix in mirrors:
        target = (prefix.rstrip("/") + "/" + url) if prefix else url
        request = urllib.request.Request(target)
        request.add_header("Range", "bytes=0-%d" % (size - 1))
        request.add_header("User-Agent", "pkg-source/2")
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                status = getattr(response, "status", 200)
                if status == 206:
                    return response.read()
                return response.read(size)
        except Exception as exc:  # 换下一个镜像
            last_error = exc
            continue
    raise RuntimeError("读取包头失败：%s" % last_error)


def read_local_prefix(path, size):
    with open(path, "rb") as handle:
        return handle.read(size)


def compute_md5(path):
    """算本地包的真实 md5。

    目录里的 md5 若为空串，部分 DSM 版本会直接忽略该条记录 —— 这是「源里明明有包、
    套件中心却一个也不显示」最可能的原因之一。远程资产拿不到 md5（GitHub 只给 sha256），
    本地包则可以现算，故本地模式下默认填真实值。
    """
    try:
        stat = os.stat(path)
    except OSError:
        return ""
    cache_key = (path, int(stat.st_mtime), stat.st_size)
    if cache_key in MD5_CACHE:
        return MD5_CACHE[cache_key]
    digest = hashlib.md5()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    MD5_CACHE[cache_key] = digest.hexdigest()
    return MD5_CACHE[cache_key]


# ---------------------------------------------------------------------------
# 版本比较与条目构造
# ---------------------------------------------------------------------------
def version_key(text):
    """把 0.2.3-alpha.2 / 20130412-3 这类版本号变成可比较的元组。

    两个关键点：
      · 数字段按数值比（rc.10 > rc.9，纯字符串比会判反）；
      · 含预发布标记的排在同号正式版之前（0.2.3-alpha.2 < 0.2.3）。
    """
    parts = [p for p in re.split(r"[._\-+]", text.strip()) if p != ""]
    if not parts:
        return (1,)
    has_tag = 1 if any(not p.isdigit() for p in parts) else 0
    # has_tag 取反：有标记的（预发布）排前面，正式版更大
    signature = [1 - has_tag]
    for part in parts:
        if part.isdigit():
            signature.append((1, int(part), 0))
        else:
            signature.append((0, 0, PRERELEASE_RANK.get(part.lower(), -1)))
    return tuple(signature)


def to_bool(value, default=False):
    if value is None:
        return default
    text = str(value).strip().lower()
    if text in ("yes", "true", "1"):
        return True
    if text in ("no", "false", "0"):
        return False
    return default


def normalize_arch(value, arch_map):
    """INFO 的 arch 可能是空格分隔的多个架构，取第一个并套别名映射。"""
    first = (value or "").strip().split(" ")[0]
    return arch_map.get(first.lower(), first)


def expand_arch_codes(arch, args):
    """把架构代码展开成目录里的 arch 数组。

    DSM 是拿**本机架构代码**去匹配这个数组的（本机 kvmx64、SA6400 是 epyc7002），
    只写 x86_64 会在这些机型上匹配不到，包根本不显示。故把同族代码全部列出。
    """
    codes = list(args.arch_expand_dict.get((arch or "").lower(), ()))
    if arch and arch not in codes:
        codes.insert(0, arch)
    return codes or ([arch] if arch else [])


def build_entry(package, arch, version, link, size, meta, args,
                release_body="", asset_download_count=0):
    """按 DSM 套件源目录的真实条目格式构造记录。

    字段与类型对齐现役实现（sspks-imnks 的 JsonOutput）实测输出：
      · category / subcategory / type / price 是**数字**（原生恒 0），写成字符串会让详情页类别异常；
      · silent_install / silent_uninstall / silent_upgrade 是**布尔**；
      · start 原生恒 true，不跟 INFO 的 qstart 走；
      · md5 / signature 即使为空也要出现，缺键会让部分 DSM 版本跳过该条；
      · beta 先留在条目里，供服务端按 package_update_channel 过滤，
        在返回给 DSM 之前会被删掉 —— 原生实现也是生成后立刻 unset 这个键。
    """

    def yes_no_bool(key, default=False):
        return to_bool(meta.get(key), default)

    entry = {
        "package": package,
        "version": version,
        "dname": meta.get("displayname") or package,
        "desc": meta.get("description") or "",
        # arch 必须是数组：DSM 拿本机架构代码去匹配，缺这个键整条都不会显示
        "arch": expand_arch_codes(arch, args),
        "price": 0,
        # 原生实现给固定展示值，DSM 只展示不校验
        # 下载次数取 Release 资产的真实计数（本地模式无此信息，按 0）
        "download_count": asset_download_count,
        "recent_download_count": 0,
        "link": link,
        "size": size,
        "md5": args.md5_map.get("%s|%s" % (package, version), ""),
        "signature": "",
        "qinst": to_bool(meta.get("qinst"), True),
        "qstart": to_bool(meta.get("qstart"), True),
        "qupgrade": to_bool(meta.get("qupgrade"), True),
        "depsers": meta.get("install_dep_services") or "",
        "deppkgs": meta.get("install_dep_packages") or "",
        "conflictpkgs": meta.get("install_conflict_packages") or "",
        # 官方源用字符串 "yes"/"no" 表达「可启动」，同时给布尔 start 兼容旧版本读取
        "startable": "yes",
        "start": True,
        "maintainer": meta.get("maintainer") or "",
        "maintainer_url": meta.get("maintainer_url") or "",
        "distributor": meta.get("distributor") or "",
        "distributor_url": meta.get("distributor_url") or "",
        "support_url": meta.get("support_url") or "",
        # 更新日志优先用 Release 说明（发版时写的对外说明）；拿不到才回落到 INFO 的 changelog
        "changelog": release_body or meta.get("changelog") or "",
        "thirdparty": True,
        "category": args.category_code,
        "subcategory": 0,
        "type": 0,
        "silent_install": yes_no_bool("silent_install"),
        # 本仓库的 SPK 目前没声明 silent_upgrade，该开关让包能进自动更新列表
        "silent_upgrade": yes_no_bool("silent_upgrade", default=args.force_silent_upgrade),
        "silent_uninstall": yes_no_bool("silent_uninstall"),
        "os_min_ver": meta.get("os_min_ver") or "",
        # 详情页「URL」一行；部分 DSM 版本读 url，原生实现只给 support_url，两个都给更稳
        "url": meta.get("support_url") or "",
        # beta 保留到服务端过滤阶段，返回前删除
        "beta": (args.beta_override == "yes") if args.beta_override != "auto"
                else to_bool(meta.get("beta"), bool(re.search(r"(alpha|beta|rc)", version, re.I))),
    }

    # 多语言：把 INFO 里的 displayname_xxx / description_xxx 收起来，
    # 响应时按请求的 language 参数覆盖 dname / desc（与原生实现的本地化方式一致）
    localized = {}
    for key, value in meta.items():
        if key.startswith("displayname_") or key.startswith("description_"):
            if value:
                localized[key] = value
    if localized:
        entry["_localized"] = localized

    # 图标：DSM 读的是**字符串数组**。实测 SynoCommunity 官方源 165 个包全部形如
    # ["…/icon_72.png", "…/icon_256.png"]，写成 [{"url": …}] 对象数组前端取不到图
    # （已装包有图标是因为它读本地 INFO，与目录无关）。
    if args.icon_url:
        base = args.icon_url.rstrip("/")
        thumb_url = "%s/icon_72.png" % base
        retina_url = "%s/icon_256.png" % base
    else:
        icon_base = (args.icon_base or "").rstrip("/")
        thumb_url = ("%s/icon/%s-72.png" % (icon_base, package)) if icon_base else ""
        retina_url = ("%s/icon/%s-256.png" % (icon_base, package)) if icon_base else ""
    if thumb_url:
        entry["thumbnail"] = [thumb_url, retina_url]
        entry["thumbnail_retina"] = [retina_url]
    # 官方源的 snapshot 多为空数组；截图要从包内 screenshots/ 提取，暂不提供
    entry["snapshot"] = []

    # 群晖原生目录没有这个键，但它是「从哪个版本起允许自动升级」的唯一开关，保留
    if args.auto_upgrade_from:
        entry["auto_upgrade_from"] = args.auto_upgrade_from
    return entry


def resolve_meta(args, name, location, link, size, guess, release_body="", asset_download_count=0):
    """按「读包头 → 解析 INFO」取元数据，返回 (entry, arch, reason) 三元组。

    location 是读取包头用的地址（本地路径或远程直链），link 是最终写进索引、
    给套件中心下载用的地址，两者在离线模式下并不相同。
    架构单独返回而不是塞进条目：每个架构一个 index 文件，而条目里不需要 arch 字段。
    """
    package = guess.get("package") or ""
    arch = normalize_arch(guess.get("arch"), args.arch_map_dict)
    version = guess.get("version") or ""
    meta = {}
    icons = {}

    if not args.no_info:
        sizes = [args.header_bytes]
        if FALLBACK_HEADER_BYTES > args.header_bytes:
            sizes.append(FALLBACK_HEADER_BYTES)
        for header_bytes in sizes:
            try:
                if args.from_spk_dir:
                    raw = read_local_prefix(location, header_bytes)
                else:
                    raw = fetch_prefix(location, header_bytes, args.mirror_list)
            except Exception as exc:
                return None, None, "读取包头失败（%s）：%s" % (name, exc)
            info_text, icons = extract_metadata_from_tar_bytes(raw)
            if info_text:
                meta = parse_info_text(info_text)
                break
        if not meta:
            return None, None, "包头前 %d 字节内未找到 INFO（%s）" % (sizes[-1], name)

    # INFO 是权威：包名与架构以它为准。版本要单独处理 ——
    # 套件中心记录「已装版本」用的是 INFO 里的 version；索引若给文件名版本，
    # 两者不在同一坐标系会比较错乱。反过来，若 INFO 没带预发布号，rc 之间的
    # 升级就完全识别不出来。故默认取 INFO，允许 --version-source filename 切换，
    # 两者不一致时给出告警而不是默默选一个。
    package = meta.get("package") or package
    info_version = meta.get("version") or ""
    name_version = guess.get("version") or ""
    version = name_version if args.version_source == "filename" else (info_version or name_version)
    if info_version and name_version and info_version != name_version:
        # 不是异常：见 VERBOSE_NOTES 上方注释（群晖 INFO 只允许数字版本）
        VERBOSE_NOTES.append("展示名与套件版本不同（%s）：INFO=%s / 资产名=%s，采用 %s"
                             % (name, info_version, name_version, version))
    if meta.get("arch"):
        arch = normalize_arch(meta.get("arch"), args.arch_map_dict)
    if not package or not version:
        return None, None, "缺少 package/version（%s）" % name
    if not arch:
        # 架构既不在资产名也不在 INFO 里：归到 noarch，避免生成 index-.json 这种坏文件名
        arch = "noarch"
        WARNINGS.append("架构未知，按 noarch 归档（%s）" % name)
    if args.arches and arch not in args.arches:
        return None, None, None  # 被 --arches 明确过滤，不算异常
    entry = build_entry(package, arch, version, link, size, meta, args,
                        release_body, asset_download_count)
    # 本地包现算真实 md5：空 md5 会让部分 DSM 版本直接跳过该条记录
    if args.from_spk_dir and not entry.get("md5"):
        entry["md5"] = compute_md5(location)
    save_icons(args.out_dir, package, icons)
    return entry, arch, None


# ---------------------------------------------------------------------------
# 数据源：本地目录 / GitHub Release
# ---------------------------------------------------------------------------
def api_json(url, token):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "pkg-source/2")
    if token:
        request.add_header("Authorization", "token " + token)
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.loads(response.read().decode("utf-8"))


def list_releases(repo, tag, count, token):
    """取要处理的 Release 列表。--tag 指定单个；否则按条数取最新的若干个。"""
    if tag and tag != "latest":
        return [api_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag), token)]
    if count <= 1:
        return [api_json("https://api.github.com/repos/%s/releases/latest" % repo, token)]
    return api_json("https://api.github.com/repos/%s/releases?per_page=%d" % (repo, count), token)


def match_asset(name, pattern, allow_fallback):
    """判断资产名是否可用，返回 (match 对象或 None, 是否走了兜底)。

    正则对历史命名存在歧义（见 DEFAULT_ASSET_REGEX 上方注释），所以当精确正则
    不匹配、但文件确实是 .spk 时，退一步只取包名前缀，架构与版本交给 INFO。
    """
    matched = pattern.search(name)
    if matched:
        return matched, False
    if allow_fallback and name.lower().endswith(".spk"):
        matched = FALLBACK_ASSET_REGEX.search(name)
        if matched:
            return matched, True
    return None, False


def collect(args, pattern, token):
    """扫描数据源，返回 {arch: {package: entry}} —— 同包同架构只留最高版本。"""
    best = {}
    skipped = []

    if args.from_spk_dir:
        sources = []
        for name in sorted(os.listdir(args.from_spk_dir)):
            path = os.path.join(args.from_spk_dir, name)
            if not os.path.isfile(path):
                continue
            matched, used_fallback = match_asset(name, pattern, not args.no_info)
            if not matched:
                skipped.append("资产名不匹配（%s）" % name)
                continue
            if used_fallback:
                WARNINGS.append("命名不符 --asset-regex，改用 INFO 兜底（%s）" % name)
            # 本地模式的下载地址走本服务的 /spk/ 路由，DSM 侧不依赖任何外网资产
            link = ("%s/spk/%s" % (args.base_url.rstrip("/"), name)) if args.base_url else name
            sources.append((name, path, os.path.getsize(path), matched.groupdict(), link, "", 0))
        if not sources:
            skipped.append("目录 %s 下没有匹配的 spk" % args.from_spk_dir)
    else:
        sources = []
        for release in list_releases(args.repo, args.tag, args.releases, token):
            tag_name = release.get("tag_name") or ""
            # Release 说明即对外更新日志；统一换行符，避免详情页显示异常
            release_body = (release.get("body") or "").replace("\r\n", "\n").strip()
            for asset in release.get("assets") or []:
                name = asset.get("name") or ""
                matched, used_fallback = match_asset(name, pattern, not args.no_info)
                if not matched:
                    skipped.append("资产名不匹配（%s @ %s）" % (name, tag_name))
                    continue
                if used_fallback:
                    WARNINGS.append("命名不符 --asset-regex，改用 INFO 兜底（%s）" % name)
                # 资产直链默认套镜像：DSM 直连 github 资产在本网络下拿不到。
                # 注意 location 必须保存**未套镜像的原始直链** —— fetch_prefix 内部会再加
                # 镜像前缀，这里若存已套好的 link 就会变成 ghfast.top/ghfast.top/...（实测 403）。
                raw_link = asset["browser_download_url"]
                link = (args.link_mirror.rstrip("/") + "/" + raw_link) if args.link_mirror else raw_link
                sources.append((name, raw_link, asset.get("size") or 0, matched.groupdict(), link,
                                release_body, asset.get("download_count") or 0))

    for name, location, size, guess, link, release_body, asset_download_count in sources:
        entry, arch, reason = resolve_meta(args, name, location, link, size, guess,
                                           release_body, asset_download_count)
        if reason:
            skipped.append(reason)
            continue
        if entry is None:
            continue
        bucket = best.setdefault(arch, {})
        previous = bucket.get(entry["package"])
        # 同包同架构只留最高版本：套件中心正是靠这条判断「有新版本可升级」
        if previous is None or version_key(entry["version"]) > version_key(previous["version"]):
            bucket[entry["package"]] = entry

    return best, skipped


def _dump_json(path, payload):
    """原子写入目录文件：先写临时文件、fsync，再 rename 覆盖。

    直接覆盖写有真实风险：套件中心每小时会来取好几次，如果它正好读到写了一半
    的文件就会拿到不完整 JSON，进而把该源里的包判定成「套件丢失」。
    rename 在同一文件系统内是原子的，读方要么看到旧文件、要么看到新文件。
    """
    directory = os.path.dirname(path) or "."
    temp_path = os.path.join(directory, ".%s.tmp" % os.path.basename(path))
    with io.open(temp_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_path, path)


def write_catalog(best, out_dir):
    """落盘目录文件。

    只产出 `catalog.json` 一份：DSM 认的是「单文件 + 每条自带 arch 数组」的结构；
    按架构分文件的 index-<arch>.json 它不认，留着只会让人误填错地址，故不再生成，
    并把历史遗留的分片文件清掉。
    """
    os.makedirs(out_dir, exist_ok=True)
    for stale in os.listdir(out_dir):
        if INDEX_NAME.match(stale):
            try:
                os.remove(os.path.join(out_dir, stale))
            except OSError:
                pass

    entries = []
    for arch in sorted(best.keys()):
        entries.extend(sorted(best[arch].values(), key=lambda item: item["package"].lower()))
    if not entries:
        return []
    path = os.path.join(out_dir, CATALOG_NAME)
    _dump_json(path, {"packages": entries})
    return [(path, len(entries))]


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------
def build_catalog_response(catalog_path, query):
    """按请求参数裁剪目录后返回 bytes；文件还没生成好时返回 None。

    对齐 sspks-imnks（现役实现）的三件事：
      1. 按 arch 过滤 —— DSM 带本机架构代码来问，同包多架构条目全返回会让它取错；
      2. 按 package_update_channel 过滤 beta 包，并把 beta 字段从响应里删掉
         （原生实现生成后立刻 unset 这个键，交给通道判断，而不是让 DSM 看这个布尔）；
      3. 按 language 把 dname/desc 换成 INFO 里的多语言版本（displayname_chs 之类）。
    没有 arch / channel / language 参数时（浏览器直连）不做裁剪，只清理内部字段。
    注意：只有**显式**传入 stable 才过滤 beta —— 缺参数就过滤会导致「浏览器打开是空数组」
    这种回归，之前踩过。
    """
    try:
        with open(catalog_path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return None

    params = urllib.parse.parse_qs(query or "")
    arch = (params.get("arch") or [""])[0].strip()
    channel = (params.get("package_update_channel") or [""])[0].strip().lower()
    language = (params.get("language") or [""])[0].strip().lower()

    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:
        return raw

    kept = []
    for item in (data.get("packages") or []):
        if arch and arch not in (item.get("arch") or []):
            continue
        if channel and channel != "beta" and item.get("beta"):
            continue
        localized = item.pop("_localized", None) or {}
        if language:
            if localized.get("displayname_" + language):
                item["dname"] = localized["displayname_" + language]
            if localized.get("description_" + language):
                item["desc"] = localized["description_" + language]
        # beta 不给 DSM 看，与原生实现一致
        item.pop("beta", None)
        kept.append(item)

    data["packages"] = kept
    return json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")


def find_local_file(candidates, name):
    """在候选目录里找同名文件，找不到返回 None。"""
    for base in candidates:
        if not base:
            continue
        candidate_path = os.path.join(base, name)
        if os.path.isfile(candidate_path):
            return candidate_path
    return None


def stream_file(handler, file_path):
    """大文件流式发送：spk 有一两百 MB，整块读进内存会直接把进程撑爆。"""
    try:
        stat_info = os.stat(file_path)
    except OSError:
        handler.send_simple(404, b"not found\n")
        return
    handler.send_response(200)
    handler.send_header("Content-Type", "application/octet-stream")
    handler.send_header("Content-Length", str(stat_info.st_size))
    handler.send_header("Content-Disposition",
                        'attachment; filename="%s"' % os.path.basename(file_path))
    handler.end_headers()
    try:
        with open(file_path, "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                handler.wfile.write(chunk)
    except (BrokenPipeError, ConnectionResetError):
        # 套件中心中途断开（常见于它自己判断取消），不算错误
        pass


def make_handler(out_dir, spk_dir=None):
    """构造 HTTP handler 类。

    只保留路由分发：目录生成、文件查找、大文件发送都已抽到模块级函数，
    这样这个类不会因为塞满业务逻辑而膨胀。
    """
    from http.server import BaseHTTPRequestHandler

    catalog_path = os.path.join(out_dir, CATALOG_NAME)
    local_dirs = (spk_dir, out_dir)

    class SourceHandler(BaseHTTPRequestHandler):
        server_version = "pkg-source/2"

        def do_GET(self):  # noqa: N802
            raw_path, _, query = self.path.partition("?")
            path = raw_path.rstrip("/") or "/"

            # 目录请求：/api/package 等固定路径，或根路径带查询参数（DSM 有时直接问根）
            if path in ("/api/package", "/nas", "/nas/package", "/package") or (path == "/" and query):
                body = build_catalog_response(catalog_path, query)
                if body is None:
                    self.send_simple(503, b"index not ready\n")
                else:
                    self.send_simple(200, body, "application/json; charset=utf-8")
                return

            if path == "/":
                self._send_help()
                return

            if path.startswith("/spk/"):
                # 本地包直接由本服务提供下载，DSM 侧不依赖任何外网资产
                file_path = find_local_file(local_dirs, os.path.basename(path))
                if file_path is None:
                    self.send_simple(404, b"not found\n")
                    return
                stream_file(self, file_path)
                return

            if path.startswith("/icon/"):
                file_path = os.path.join(out_dir, "icons", os.path.basename(path))
                try:
                    with open(file_path, "rb") as handle:
                        body = handle.read()
                except OSError:
                    self.send_simple(404, b"not found\n")
                    return
                self.send_simple(200, body, "image/png")
                return

            self.send_simple(404, b"not found\n")

        def _send_help(self):
            host = self.headers.get("Host") or "127.0.0.1"
            text = ("pkg-source 运行中。\n\n"
                    "套件中心 → 设置 → 套件来源 → 新增，填：\n"
                    "  http://%s/api/package\n\n"
                    "兼容路径：/nas、/nas/package；根路径带查询参数时同样返回目录。\n"
                    "本地包下载：/spk/<文件名>\n" % host)
            self.send_simple(200, text.encode("utf-8"))

        def send_simple(self, status, body, content_type="text/plain; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *arg_list):
            log("HTTP %s" % (fmt % arg_list))

    return SourceHandler


def lan_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("223.5.5.5", 80))
        return probe.getsockname()[0]
    except Exception:
        return "<本机局域网IP>"
    finally:
        probe.close()


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def refresh(args, pattern, token):
    try:
        best, skipped = collect(args, pattern, token)
    except Exception as exc:
        log("刷新失败：%s" % exc)
        return False
    written = write_catalog(best, args.out_dir)
    detail = "；".join("%s（%d 条）" % (os.path.basename(p), n) for p, n in written) or "无产物"
    log("目录已刷新：%s" % detail)
    for item in sorted(set(WARNINGS)):
        log("⚠ 注意：%s" % item)
    del WARNINGS[:]
    if args.verbose:
        for item in sorted(set(VERBOSE_NOTES)):
            log("· %s" % item)
    del VERBOSE_NOTES[:]
    for item in skipped:
        log("⚠ 跳过：%s" % item)
    return bool(written)


def build_parser():
    """构造命令行参数解析器。纯声明，不做校验。"""
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--repo", default="", help="owner/repo；与 --from-spk-dir 二选一")
    parser.add_argument("--tag", default="latest", help="固定某个 Release tag，缺省 latest")
    parser.add_argument("--releases", type=int, default=1,
                        help="聚合最近 N 个 Release（同包同架构取最高版本），缺省 1")
    parser.add_argument("--asset-regex", default=DEFAULT_ASSET_REGEX,
                        help="资产名初筛正则，须含 package/arch/version 三个命名组")
    parser.add_argument("--arches", nargs="*", default=[], help="只保留这些架构（缺省全收）")
    parser.add_argument("--arch-map", default=DEFAULT_ARCH_MAP, help="架构别名映射 aarch64=armv8,amd64=x86_64")
    parser.add_argument("--from-spk-dir", default="", help="离线：直接读本地 spk 目录")
    parser.add_argument("--base-url", default="", help="离线模式下写入 link 的前缀")
    parser.add_argument("--mirror", default=DEFAULT_MIRRORS,
                        help="读包头的镜像前缀候选，逗号分隔，空串表示直连，缺省 ghfast.top 优先")
    parser.add_argument("--link-mirror", default="https://ghfast.top/",
                        help="写进目录的下载地址镜像前缀（给套件中心下载用），空串表示用原始 GitHub 直链")
    parser.add_argument("--header-bytes", type=int, default=DEFAULT_HEADER_BYTES,
                        help="读取包头字节数，缺省 64KB（实测 INFO 在前 8KB）")
    parser.add_argument("--no-info", action="store_true",
                        help="不读 SPK 内 INFO，退回纯文件名解析（首版行为，仅排障用）")
    parser.add_argument("--version-source", choices=("info", "filename"), default="info",
                        help="版本号取自 INFO（缺省，与套件中心已装记录同源）还是资产名")
    parser.add_argument("--verbose", action="store_true",
                        help="输出展示名与套件版本差异等说明信息（默认不打印，属群晖数字版本规范）")
    parser.add_argument("--arch-expand", default=DEFAULT_ARCH_EXPAND,
                        help="架构代码族展开，格式 '族=码,码;族2=码,码'；DSM 用本机代码匹配 arch 数组")
    parser.add_argument("--icon-base", default=None,
                        help="图标 URL 前缀，缺省用 http://<本机IP>:<端口>；传空串则不输出缩略图")
    parser.add_argument("--md5-file", default="",
                        help="md5 清单：每行 '<package>|<version> <md5>' 或 '<文件名> <md5>'")
    parser.add_argument("--spk-dir", default="",
                        help="本地 spk 目录，供 /spk/<文件名> 直接下载；缺省沿用 --from-spk-dir")
    parser.add_argument("--beta", dest="beta_override", choices=("auto", "yes", "no"), default="auto",
                        help="beta 标记：auto 按 INFO（缺省）；no 强制标为正式版，让 stable 通道的套件中心也能看到")
    parser.add_argument("--category-code", type=int, default=0,
                        help="详情页「类别」代码；原生目录恒为 0，且是数字不是字符串")
    parser.add_argument("--icon-url", default="",
                        help="外部图标地址基准，如 https://example.com/syno/images；给了就用它的 icon_72.png/icon_256.png")
    parser.add_argument("--force-silent-upgrade", action="store_true",
                        help="INFO 未声明 silent_upgrade 时，输出里补 true（让包进自动更新列表）")
    parser.add_argument("--auto-upgrade-from", default="",
                        help="INFO 未声明 auto_upgrade_from 时用这个版本号填充")
    parser.add_argument("--out-dir", default=".pkg-source", help="目录输出目录，缺省 ./.pkg-source")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--interval", type=int, default=1800, help="刷新间隔秒")
    parser.add_argument("--once", action="store_true", help="生成一次即退出（cron）")
    parser.add_argument("--check", action="store_true", help="只生成并打印，不起服务")
    return parser


def load_md5_map(path):
    """读 md5 清单：每行 '<package>|<version> <md5>' 或 '<文件名> <md5>'。

    GitHub 只给 sha256，md5 要么由本地包算出，要么外部提供；都没有就留空。
    """
    mapping = {}
    if not path or not os.path.isfile(path):
        return mapping
    with io.open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 2:
                mapping[parts[0]] = parts[1]
    return mapping


def prepare_args(parser, args):
    """校验参数并派生运行时字段，返回编译好的资产名正则。

    派生的东西都挂在 args 上：正则、架构别名、架构代码族、md5 表、镜像候选、
    输出与本地包目录的绝对路径。
    """
    if not args.repo and not args.from_spk_dir:
        parser.error("需要 --repo 或 --from-spk-dir")

    try:
        pattern = re.compile(args.asset_regex)
    except re.error as exc:
        parser.error("--asset-regex 非法：%s" % exc)
    for group_name in ("package", "arch", "version"):
        if group_name not in pattern.groupindex:
            parser.error("--asset-regex 缺少命名组 %r" % group_name)

    args.arch_map_dict = {}
    for pair in (args.arch_map or "").split(","):
        if "=" in pair:
            left, right = pair.split("=", 1)
            args.arch_map_dict[left.strip().lower()] = right.strip().strip("/")

    # 架构代码族：'族=码,码;族2=码,码'
    args.arch_expand_dict = {}
    for family_group in (args.arch_expand or "").split(";"):
        if "=" not in family_group:
            continue
        family, codes = family_group.split("=", 1)
        args.arch_expand_dict[family.strip().lower()] = [
            code.strip() for code in codes.split(",") if code.strip()
        ]

    args.md5_map = load_md5_map(args.md5_file)

    # 图标默认由本服务托管，套件中心能直接取到
    if args.icon_base is None:
        args.icon_base = "http://%s:%d" % (lan_ip(), args.port)

    args.mirror_list = [item.strip() for item in (args.mirror or "").split(",") if item.strip()]
    # 直连永远排在最后兜底：镜像挂了不该等同于彻底读不到（直连失败只是慢，不会被吞掉）
    args.mirror_list.append("")

    args.out_dir = os.path.abspath(args.out_dir)
    # 本地包目录：既用于解析（--from-spk-dir 时）也用于 /spk/ 下载
    args.spk_dir = os.path.abspath(args.spk_dir or args.from_spk_dir) if (args.spk_dir or args.from_spk_dir) else ""
    return pattern


def serve(args, pattern, token):
    """先刷新一次目录，再起 HTTP 服务并周期刷新。"""
    from http.server import ThreadingHTTPServer

    ok = refresh(args, pattern, token)
    if not ok:
        log("首次生成失败；服务仍启动（DSM 会看到 503），下次刷新成功即恢复")

    server = ThreadingHTTPServer((args.bind, args.port), make_handler(args.out_dir, args.spk_dir))

    def loop():
        while True:
            time.sleep(max(60, args.interval))
            refresh(args, pattern, token)

    threading.Thread(target=loop, daemon=True).start()

    host = lan_ip()
    log("套件源就绪（来源 %s）。DSM 套件中心 → 设置 → 套件来源 → 新增：" % (args.repo or args.from_spk_dir))
    log("  http://%s:%d/api/package" % (host, args.port))
    if args.spk_dir:
        log("  本地包下载：http://%s:%d/spk/<文件名>（目录 %s）" % (host, args.port, args.spk_dir))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("收到中断，退出")
    return 0


def main():
    parser = build_parser()
    args = parser.parse_args()
    pattern = prepare_args(parser, args)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

    if args.check or args.once:
        return 0 if refresh(args, pattern, token) else 2
    return serve(args, pattern, token)


if __name__ == "__main__":
    sys.exit(main())
