#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pkg-source.py — 把任意 GitHub 仓库的 Release 变成 DSM 套件源（单文件，仅 python3 标准库）。

零耦合的定义（本文件遵守的三条）：
  1. 不 import 任何项目代码、不读任何项目文件 —— 拷到任意目录、任意机器都能直接跑；
  2. 不假设任何仓库的产物命名：资产怎么匹配、架构怎么归类、package 叫什么，全部由参数决定；
  3. spk 的下载由**套件中心**完成 —— 本工具只产出索引 JSON，默认一个字节都不下载。

它做的事只有一件：给定仓库 + 匹配规则，把匹配到的 Release 资产整理成
  index-<arch>.json: {"packages":[{package, version, link, size, ...}]}
挂在一个 HTTP 端口上，DSM 套件中心把它当「套件来源」即可。

最基本的用法（用示例正则适配常见命名 <包名>_<架构>-<版本>.spk）
  python3 pkg-source.py --repo owner/repo --port 8899

其它仓库命名不同就改正则（--asset-regex，必须含 package/arch/version 三个命名组）
  python3 pkg-source.py --repo owner/repo \
      --asset-regex '(?P<package>[^-]+)-(?P<arch>[0-9a-z_]+)-(?P<version>[0-9][\\w.\\-]*)\.spk'

只想看会生成什么，不起服务
  python3 pkg-source.py --repo owner/repo --check

用本地已有的 spk 目录（完全不联网）
  python3 pkg-source.py --from-spk-dir ./dist --base-url https://example.com/dl --check

环境变量
  GH_TOKEN / GITHUB_TOKEN   访问 GitHub API 的令牌（匿名 60 次/小时，建议给）
"""
from __future__ import print_function

import argparse
import io
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_ASSET_REGEX = r"(?P<package>[^_/]+)_(?P<arch>[A-Za-z0-9_]+)-(?P<version>[0-9][\w.\-]*)\.spk$"
INDEX_NAME = re.compile(r"^index-([A-Za-z0-9_]+)\.json$")


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


def api_json(url, token):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", "token " + token)
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.loads(response.read().decode("utf-8"))


def resolve_release(repo, tag, token):
    if tag and tag != "latest":
        return api_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag), token)
    return api_json("https://api.github.com/repos/%s/releases/latest" % repo, token)


def collect_entries(assets, pattern, arches, arch_map):
    """把资产列表整理成 {arch: [entry...]}；不下载、不读包内信息。"""
    by_arch, skipped = {}, []
    for asset in assets:
        name = asset.get("name") or ""
        matched = pattern.search(name)
        if not matched:
            continue
        groups = matched.groupdict()
        arch = groups.get("arch") or ""
        arch = arch_map.get(arch.lower(), arch)
        if arches and arch not in arches:
            continue
        version = groups.get("version") or ""
        package = groups.get("package") or ""
        if not package or not version:
            skipped.append("%s：正则未取到 package/version" % name)
            continue
        by_arch.setdefault(arch, []).append({
            "package": package,
            "dname": package,
            "version": version,
            "link": asset["browser_download_url"],
            "size": asset.get("size") or 0,
            "startable": "yes",
            "qinst": False, "qstart": False, "qupgrade": False,
        })
    return by_arch, skipped


def collect_from_dir(directory, pattern, arches, arch_map, base_url):
    assets = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        link = (base_url.rstrip("/") + "/" + name) if base_url else name
        assets.append({"name": name, "size": os.path.getsize(path), "browser_download_url": link})
    return collect_entries(assets, pattern, arches, arch_map)


def write_indexes(by_arch, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for arch, entries in sorted(by_arch.items()):
        path = os.path.join(out_dir, "index-%s.json" % arch)
        with io.open(path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump({"packages": entries}, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        written.append((path, len(entries)))
    return written


class Handler(BaseHTTPRequestHandler):
    server_version = "pkg-source/1"
    out_dir = "."

    def do_GET(self):  # noqa: N802
        name = self.path.split("?")[0].lstrip("/")
        if not INDEX_NAME.match(name):
            self._send(404, b"not found\n")
            return
        try:
            with open(os.path.join(Handler.out_dir, name), "rb") as handle:
                body = handle.read()
        except OSError:
            self._send(503, b"index not ready\n")
            return
        self._send(200, body, "application/json; charset=utf-8")

    def _send(self, status, body, content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log("HTTP %s" % (fmt % args))


def lan_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("223.5.5.5", 80))
        return probe.getsockname()[0]
    except Exception:
        return "<本机局域网IP>"
    finally:
        probe.close()


def refresh(args, pattern, token):
    try:
        if args.from_spk_dir:
            tag = "(local)"
            by_arch, skipped = collect_from_dir(
                args.from_spk_dir, pattern, args.arches, args.arch_map_dict, args.base_url)
        else:
            release = resolve_release(args.repo, args.tag, token)
            tag = release.get("tag_name") or args.tag
            by_arch, skipped = collect_entries(
                release.get("assets") or [], pattern, args.arches, args.arch_map_dict)
    except Exception as exc:
        log("刷新失败：%s" % exc)
        return False
    written = write_indexes(by_arch, args.out_dir)
    detail = "；".join("%s（%d 条）" % (os.path.basename(p), n) for p, n in written) or "无产物"
    log("索引已刷新（tag=%s）：%s" % (tag, detail))
    for item in skipped:
        log("⚠ 跳过：%s" % item)
    return bool(written)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--repo", default="", help="owner/repo；与 --from-spk-dir 二选一")
    parser.add_argument("--tag", default="latest", help="Release tag，缺省 latest")
    parser.add_argument("--asset-regex", default=DEFAULT_ASSET_REGEX,
                        help="资产匹配正则，必须含 package / arch / version 三个命名组")
    parser.add_argument("--arches", nargs="*", default=[], help="只保留这些架构（缺省全收）")
    parser.add_argument("--arch-map", default="aarch64=armv8,amd64=x86_64",
                        help="架构别名映射，形如 aarch64=armv8,amd64=x86_64")
    parser.add_argument("--from-spk-dir", default="", help="离线：直接读本地 spk 目录")
    parser.add_argument("--base-url", default="", help="离线模式下写入 link 的前缀")
    parser.add_argument("--out-dir", default=".pkg-source", help="索引输出目录（缺省 ./.pkg-source）")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--interval", type=int, default=1800, help="刷新间隔秒")
    parser.add_argument("--once", action="store_true", help="生成一次即退出（cron）")
    parser.add_argument("--check", action="store_true", help="只生成并打印，不起服务")
    args = parser.parse_args()

    if not args.repo and not args.from_spk_dir:
        parser.error("需要 --repo 或 --from-spk-dir")

    try:
        pattern = re.compile(args.asset_regex)
    except re.error as exc:
        parser.error("--asset-regex 非法：%s" % exc)
    for group in ("package", "arch", "version"):
        if group not in pattern.groupindex:
            parser.error("--asset-regex 缺少命名组 %r" % group)

    arch_map = {}
    for pair in (args.arch_map or "").split(","):
        if "=" in pair:
            left, right = pair.split("=", 1)
            arch_map[left.strip().lower()] = right.strip().strip("/")
    args.arch_map_dict = arch_map

    args.out_dir = os.path.abspath(args.out_dir)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

    ok = refresh(args, pattern, token)
    if args.check or args.once:
        return 0 if ok else 2
    if not ok:
        log("首次生成失败；服务仍启动（DSM 会看到 503），下次刷新成功即恢复")

    Handler.out_dir = args.out_dir
    server = ThreadingHTTPServer((args.bind, args.port), Handler)

    def loop():
        while True:
            time.sleep(max(60, args.interval))
            refresh(args, pattern, token)

    threading.Thread(target=loop, daemon=True).start()

    host = lan_ip()
    log("套件源就绪（来源 %s）。DSM 套件中心 → 设置 → 套件来源 添加：" % (args.repo or args.from_spk_dir))
    for name in sorted(os.listdir(args.out_dir)) if os.path.isdir(args.out_dir) else []:
        if INDEX_NAME.match(name):
            arch = name[len("index-"):-len(".json")]
            log("  %-8s → http://%s:%d/%s" % (arch, host, args.port, name))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("收到中断，退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
