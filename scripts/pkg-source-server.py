#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pkg-source-server.py — 独立的「局域网 SPK 套件源」服务（只依赖 python3 标准库）。

定位：与本项目的套件、启动脚本、反代**完全解耦**。它是一个可单独运行的进程：
  · 自己起一个 HTTP 端口，提供 DSM 套件中心要读的索引 JSON；
  · 自己从 GitHub Release 取数据（索引资产优先，没有就下载 spk 现算 md5）；
  · 定期自动刷新，套件中心下次检查时就能看到新版本。

DSM 侧一次性配置：套件中心 → 设置 → 套件来源 → 新增，填
  http://<本机局域网IP>:<端口>/index-x86_64.json      （x86_64 机型）
  http://<本机局域网IP>:<端口>/index-armv8.json       （armv8 机型）
之后套件中心会显示「可更新」，用户可在那里勾自动更新。

数据来源两种模式
  1) Release 索引资产（推荐）：CI 发布时把 index-<arch>.json 一并上传，本服务只拉几 KB。
  2) 回退：Release 里没有索引资产时，直接下载 spk 资产并流式计算 md5（每个约 190MB，仅在版本变化时发生）。

用法
  python3 scripts/pkg-source-server.py --port 8899                     # 起服务，默认每 30 分钟刷新
  python3 scripts/pkg-source-server.py --port 8899 --tag dsh-v<版本>    # 指定 tag（默认取最新 Release）
  python3 scripts/pkg-source-server.py --once                           # 只生成索引后退出（给 cron 用）
  python3 scripts/pkg-source-server.py --from-spk-dir ./build/staging \
          --base-url https://example.com/releases --port 8899           # 离线：用本地 spk 生成索引
  python3 scripts/pkg-source-server.py --check                          # 只打印将要生成的内容，不起服务

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
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXPECTED_ARCHES = ("x86_64", "armv8")
SPK_PATTERN = re.compile(r"_(?P<arch>x86_64|armv8)-(?P<ver>.+)\.spk$")
INDEX_NAME = re.compile(r"^index-(x86_64|armv8)\.json$")
DEFAULT_REPO = "EIGHTfs/DeepSeekHarness-NAS"


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


def http_get_json(url, token=""):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", "token %s" % token)
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.loads(response.read().decode("utf-8"))


def http_download(url, dest, token=""):
    """流式下载（spk 可能上百 MB，不能读进内存）。"""
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", "token %s" % token)
    with urllib.request.urlopen(request, timeout=120) as response, open(dest, "wb") as handle:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)
    return dest


def md5_of(path):
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(4 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def read_spk_info(path):
    """读 spk 外层 tar 里的 INFO（纯 key=value 文本）。"""
    import tarfile
    with tarfile.open(path, "r:") as outer:
        member = None
        for candidate in outer.getmembers():
            if candidate.name.lstrip("./") == "INFO":
                member = candidate
                break
        if member is None:
            return {}
        raw = outer.extractfile(member).read().decode("utf-8", "replace")
    info = {}
    for line in raw.splitlines():
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        info[key.strip()] = value.strip().strip('"')
    return info


def entry_from_spk(path, link):
    info = read_spk_info(path)
    version = info.get("version")
    if not version:
        raise ValueError("spk 内 INFO 缺 version：%s" % path)
    return {
        "package": info.get("package") or "DeepSeekHarness-NAS",
        "dname": info.get("displayname") or "DeepSeekRuntime NAS",
        "desc": "在 NAS 上以套件方式运行 DeepSeekRuntime（DSH）Web 版。",
        "version": version,
        "link": link,
        "md5": md5_of(path),
        "size": os.path.getsize(path),
        "distributor": "DeepSeekHarness-NAS",
        "distributor_url": "https://github.com/%s" % DEFAULT_REPO,
        "maintainer": "EIGHTfs",
        "maintainer_url": "https://github.com/EIGHTfs",
        "changelog": info.get("changelog") or "",
        "qinst": False,
        "qstart": False,
        "qupgrade": False,
        "startable": "yes",
    }


def build_from_local(spk_dir, base_url, out_dir):
    """离线模式：用本地 spk 目录生成索引。"""
    by_arch = {}
    for name in sorted(os.listdir(spk_dir)):
        if not name.endswith(".spk"):
            continue
        matched = SPK_PATTERN.search(name)
        if not matched:
            continue
        path = os.path.join(spk_dir, name)
        link = (base_url.rstrip("/") + "/" + name) if base_url else name
        by_arch.setdefault(matched.group("arch"), []).append(entry_from_spk(path, link))
    return write_indexes(by_arch, out_dir)


def write_indexes(by_arch, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for arch, entries in by_arch.items():
        target = os.path.join(out_dir, "index-%s.json" % arch)
        with io.open(target, "w", encoding="utf-8", newline="\n") as handle:
            json.dump({"packages": entries}, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        written.append((target, len(entries)))
    return written


def resolve_release(repo, tag, token):
    if tag and tag != "latest":
        return http_get_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag), token)
    return http_get_json("https://api.github.com/repos/%s/releases/latest" % repo, token)


def build_from_release(repo, tag, token, out_dir, work_dir):
    """优先拉 Release 里的 index 资产；没有就下载 spk 现算。"""
    release = resolve_release(repo, tag, token)
    tag_name = release.get("tag_name") or tag
    assets = release.get("assets") or []
    index_assets = [a for a in assets if INDEX_NAME.match(a.get("name") or "")]
    written = []
    if index_assets:
        for asset in index_assets:
            dest = os.path.join(out_dir, asset["name"])
            http_download(asset["browser_download_url"], dest, token)
            with io.open(dest, encoding="utf-8") as handle:
                count = len((json.load(handle) or {}).get("packages") or [])
            written.append((dest, count))
        return tag_name, written, "release-index"

    os.makedirs(work_dir, exist_ok=True)
    by_arch = {}
    for asset in assets:
        name = asset.get("name") or ""
        matched = SPK_PATTERN.search(name)
        if not matched:
            continue
        local = os.path.join(work_dir, name)
        if not os.path.isfile(local) or os.path.getsize(local) != asset.get("size"):
            log("下载 %s（%.0f MB）" % (name, (asset.get("size") or 0) / 1048576))
            http_download(asset["browser_download_url"], local, token)
        by_arch.setdefault(matched.group("arch"), []).append(
            entry_from_spk(local, asset["browser_download_url"]))
    written = write_indexes(by_arch, out_dir)
    return tag_name, written, "downloaded-spk"


class Handler(BaseHTTPRequestHandler):
    server_version = "dsh-pkg-source/1"
    state = {}

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler 约定
        name = self.path.split("?")[0].lstrip("/")
        if not INDEX_NAME.match(name):
            self._send(404, "text/plain; charset=utf-8", b"not found\n")
            return
        target = os.path.join(Handler.state.get("out_dir", "."), name)
        try:
            with open(target, "rb") as handle:
                body = handle.read()
        except OSError:
            self._send(503, "text/plain; charset=utf-8", b"index not ready\n")
            return
        self._send(200, "application/json; charset=utf-8", body)

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        log("HTTP %s" % (fmt % args))


def refresh(args, token):
    written = []
    try:
        if args.from_spk_dir:
            written = build_from_local(args.from_spk_dir, args.base_url, args.out_dir)
            tag_name, source = "(local)", "local-spk"
        else:
            tag_name, written, source = build_from_release(
                args.repo, args.tag, token, args.out_dir, args.work_dir)
    except Exception as exc:
        log("刷新失败：%s" % exc)
        return False
    detail = "；".join("%s（%d 条）" % (os.path.basename(p), n) for p, n in written)
    log("索引已刷新（tag=%s，来源=%s）：%s" % (tag_name, source, detail or "无产物"))
    missing = [a for a in EXPECTED_ARCHES if not os.path.isfile(os.path.join(args.out_dir, "index-%s.json" % a))]
    if missing:
        log("⚠ 缺架构索引：%s（该架构的机型加源后会看不到包）" % "、".join(missing))
    return bool(written)


def lan_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("223.5.5.5", 80))
        return probe.getsockname()[0]
    except Exception:
        return "<本机局域网IP>"
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/repo，缺省 %s" % DEFAULT_REPO)
    parser.add_argument("--tag", default="latest", help="指定 Release tag；缺省取最新")
    parser.add_argument("--port", type=int, default=8899, help="监听端口（缺省 8899）")
    parser.add_argument("--bind", default="0.0.0.0", help="监听地址（缺省 0.0.0.0，局域网可达）")
    parser.add_argument("--interval", type=int, default=1800, help="刷新间隔秒（缺省 1800）")
    parser.add_argument("--out-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".pkg-source"),
                        help="索引落盘目录（缺省 <repo>/.pkg-source，已 gitignore）")
    parser.add_argument("--work-dir", default="/tmp/dsh-pkg-source", help="下载 spk 的临时目录")
    parser.add_argument("--from-spk-dir", default="", help="离线模式：从本地 spk 目录生成索引")
    parser.add_argument("--base-url", default="", help="离线模式下写进 link 的前缀")
    parser.add_argument("--once", action="store_true", help="只生成索引后退出（cron 用）")
    parser.add_argument("--check", action="store_true", help="只打印将生成的内容，不起服务")
    args = parser.parse_args()

    args.out_dir = os.path.abspath(args.out_dir)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

    ok = refresh(args, token)
    if args.check:
        return 0 if ok else 2
    if args.once:
        return 0 if ok else 2
    if not ok:
        log("首次生成失败，服务仍会启动（DSM 会看到 503，直到下次刷新成功）")

    Handler.state["out_dir"] = args.out_dir
    server = ThreadingHTTPServer((args.bind, args.port), Handler)

    def loop():
        while True:
            time.sleep(max(60, args.interval))
            refresh(args, token)

    threading.Thread(target=loop, daemon=True).start()

    host = lan_ip()
    log("套件源已就绪，DSM 套件中心 → 设置 → 套件来源 添加：")
    log("  x86_64 机型：http://%s:%d/index-x86_64.json" % (host, args.port))
    log("  armv8  机型：http://%s:%d/index-armv8.json" % (host, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("收到中断，退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
