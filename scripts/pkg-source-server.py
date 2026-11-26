#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pkg-source-server.py — 通用「GitHub Release → 群晖 SPK 套件源」服务（仅依赖 python3 标准库）。

用途：给任意 GitHub 仓库，把它的 Release 资产（*.spk）变成一个 DSM 套件中心可用的套件源。
  · 不依赖被服务仓库做任何配合（不需要它产出索引、不需要改它的 CI）；
  · 不与被服务的项目耦合：本脚本可独立部署在任何一台能访问 GitHub 的机器上。

它自己完成三件事：
  1. 用 GitHub API 列出目标仓库某个 Release 的全部 *.spk 资产；
  2. 从文件名取架构（_x86_64- / _armv8-），下载后读 spk 内 INFO 得到 package/version/changelog，
     并流式计算 md5（DSM 只认 md5，而 GitHub 只给 sha256，所以必须本地算一次）；
  3. 起 HTTP 端口，按架构提供 index-<arch>.json；定期刷新，套件中心下次检查即可见新版本。

下载缓存：按「资产名 + 大小 + 更新时间」落盘复用，版本没变就不会重复下 190 MB。

用法
  python3 scripts/pkg-source-server.py --repo EIGHTfs/DeepSeekHarness-NAS --port 8899
  python3 scripts/pkg-source-server.py --repo <owner/repo> --tag v1.2.3 --port 8899
  python3 scripts/pkg-source-server.py --repo <owner/repo> --check            # 只生成并打印，不起服务
  python3 scripts/pkg-source-server.py --repo <owner/repo> --once             # 生成一次即退出（cron）
  python3 scripts/pkg-source-server.py --from-spk-dir ./staging --base-url https://…   # 离线：用本地 spk

环境变量
  GH_TOKEN / GITHUB_TOKEN   访问 GitHub API 的令牌（匿名 60 次/小时，建议给）

DSM 侧（一次性）
  套件中心 → 设置 → 套件来源 → 新增，填 http://<运行本脚本的机器IP>:<端口>/index-<架构>.json
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
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARCH_IN_NAME = re.compile(r"_(?P<arch>x86_64|armv8|aarch64)-(?P<rest>.+)\.spk$", re.IGNORECASE)
INDEX_NAME = re.compile(r"^index-(x86_64|armv8)\.json$")
ARCH_ALIASES = {"aarch64": "armv8"}


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


def api_json(url, token):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", "token " + token)
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.loads(response.read().decode("utf-8"))


def download(url, dest, token, expected_size=0, attempts=5):
    """带断点续传与重试的下载：GitHub 大文件在弱网下经常被中途掐断，重下 190 MB 代价太大。"""
    for attempt in range(1, attempts + 1):
        have = os.path.getsize(dest) if os.path.isfile(dest) else 0
        if expected_size and have == expected_size:
            return dest
        request = urllib.request.Request(url)
        request.add_header("Accept", "application/octet-stream")
        if token:
            request.add_header("Authorization", "token " + token)
        if have:
            request.add_header("Range", "bytes=%d-" % have)
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                mode = "ab" if have and response.status == 206 else "wb"
                with open(dest, mode) as handle:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        handle.write(chunk)
        except Exception as exc:
            got = os.path.getsize(dest) if os.path.isfile(dest) else 0
            log("下载中断（第 %d/%d 次，已得 %.0f%%）：%s" % (
                attempt, attempts, (got * 100.0 / expected_size) if expected_size else 0, exc))
            time.sleep(min(10, 2 * attempt))
            continue
        if not expected_size or os.path.getsize(dest) == expected_size:
            return dest
    got = os.path.getsize(dest) if os.path.isfile(dest) else 0
    raise IOError("下载未完成：%s（%d/%d 字节）" % (dest, got, expected_size))


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
    """读 spk 外层 tar 内的 INFO（纯 key=value）。不依赖被服务项目的任何约定。"""
    import tarfile
    try:
        with tarfile.open(path, "r:") as outer:
            for member in outer.getmembers():
                if member.name.lstrip("./") == "INFO":
                    raw = outer.extractfile(member).read().decode("utf-8", "replace")
                    break
            else:
                return {}
    except Exception:
        return {}
    info = {}
    for line in raw.splitlines():
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        info[key.strip()] = value.strip().strip('"')
    return info


def make_entry(spk_path, link):
    info = read_spk_info(spk_path)
    package = info.get("package") or os.path.basename(spk_path).split("_")[0]
    entry = {
        "package": package,
        "dname": info.get("displayname") or package,
        "desc": info.get("description") or info.get("desc") or "",
        "version": info.get("version") or "",
        "link": link,
        "md5": md5_of(spk_path),
        "size": os.path.getsize(spk_path),
        "distributor": info.get("distributor") or package,
        "distributor_url": info.get("distributor_url") or "",
        "maintainer": info.get("maintainer") or "",
        "maintainer_url": info.get("maintainer_url") or "",
        "changelog": info.get("changelog") or "",
        "qinst": False,
        "qstart": False,
        "qupgrade": False,
        "startable": "yes",
    }
    if not entry["version"]:
        raise ValueError("%s 内 INFO 缺 version，DSM 无法比较版本" % os.path.basename(spk_path))
    return entry


def cached_download(asset, work_dir, token):
    """按「名字+大小+更新时间」缓存；版本没变就不重复下载 190 MB。"""
    name = asset["name"]
    stamp = "%s-%s" % (asset.get("size"), (asset.get("updated_at") or "").replace(":", ""))
    target = os.path.join(work_dir, stamp + "-" + name)
    if os.path.isfile(target) and os.path.getsize(target) == asset.get("size"):
        return target
    for stale in os.listdir(work_dir):
        if stale.endswith("-" + name):
            try:
                os.remove(os.path.join(work_dir, stale))
            except OSError:
                pass
    log("下载 %s（%.0f MB）" % (name, (asset.get("size") or 0) / 1048576.0))
    return download(asset["browser_download_url"], target, token, asset.get("size") or 0)


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


def resolve_release(repo, tag, token):
    if tag and tag != "latest":
        return api_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag), token)
    return api_json("https://api.github.com/repos/%s/releases/latest" % repo, token)


def entry_from_asset(asset, arch, token, work_dir, want_md5, want_info):
    """默认**不下载**：套件中心自己会去下 spk，我们只需要给出 index 条目。
       版本取资产名里的 <版本> 段，size 取 API 值；md5 与 INFO 详情只在显式要求时才下载。"""
    name = asset["name"]
    matched = ARCH_IN_NAME.search(name)
    version = (matched.group("rest") if matched else "").strip("-")
    package = name.split("_")[0]
    entry = {
        "package": package,
        "dname": package,
        "version": version,
        "link": asset["browser_download_url"],
        "size": asset.get("size") or 0,
        "startable": "yes",
        "qinst": False, "qstart": False, "qupgrade": False,
    }
    if want_md5 or want_info:
        local = cached_download(asset, work_dir, token)
        if want_md5:
            entry["md5"] = md5_of(local)
        if want_info:
            info = read_spk_info(local)
            entry["package"] = info.get("package") or package
            entry["dname"] = info.get("displayname") or entry["package"]
            entry["version"] = info.get("version") or version
            entry["changelog"] = info.get("changelog") or ""
            for key in ("distributor", "distributor_url", "maintainer", "maintainer_url", "description"):
                if info.get(key):
                    entry["desc" if key == "description" else key] = info[key]
    return entry


def build_from_release(repo, tag, token, out_dir, work_dir, arches, want_md5=False, want_info=False):
    release = resolve_release(repo, tag, token)
    tag_name = release.get("tag_name") or tag
    by_arch, skipped = {}, []
    for asset in release.get("assets") or []:
        matched = ARCH_IN_NAME.search(asset.get("name") or "")
        if not matched:
            continue
        arch = ARCH_ALIASES.get(matched.group("arch").lower(), matched.group("arch").lower())
        if arches and arch not in arches:
            continue
        try:
            by_arch.setdefault(arch, []).append(
                entry_from_asset(asset, arch, token, work_dir, want_md5, want_info))
        except Exception as exc:
            skipped.append("%s: %s" % (asset.get("name"), exc))
    return tag_name, write_indexes(by_arch, out_dir), skipped


def build_from_local(spk_dir, base_url, out_dir, arches):
    by_arch, skipped = {}, []
    for name in sorted(os.listdir(spk_dir)):
        matched = ARCH_IN_NAME.search(name)
        if not matched:
            continue
        arch = ARCH_ALIASES.get(matched.group("arch").lower(), matched.group("arch").lower())
        if arches and arch not in arches:
            continue
        link = (base_url.rstrip("/") + "/" + name) if base_url else name
        try:
            by_arch.setdefault(arch, []).append(make_entry(os.path.join(spk_dir, name), link))
        except ValueError as exc:
            skipped.append("%s: %s" % (name, exc))
    return "(local)", write_indexes(by_arch, out_dir), skipped


class Handler(BaseHTTPRequestHandler):
    server_version = "dsh-pkg-source/2"
    state = {}

    def do_GET(self):  # noqa: N802
        name = self.path.split("?")[0].lstrip("/")
        if not INDEX_NAME.match(name):
            self._send(404, b"not found\n")
            return
        target = os.path.join(Handler.state.get("out_dir", "."), name)
        try:
            with open(target, "rb") as handle:
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


def refresh(args, token):
    try:
        if args.from_spk_dir:
            tag, written, skipped = build_from_local(args.from_spk_dir, args.base_url, args.out_dir, args.arches)
        else:
            tag, written, skipped = build_from_release(
                args.repo, args.tag, token, args.out_dir, args.work_dir, args.arches,
                want_md5=args.with_md5, want_info=args.deep)
    except Exception as exc:
        log("刷新失败：%s" % exc)
        return False
    detail = "；".join("%s（%d 条）" % (os.path.basename(p), n) for p, n in written) or "无产物"
    log("索引已刷新（tag=%s）：%s" % (tag, detail))
    for item in skipped:
        log("⚠ 跳过：%s" % item)
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
    parser.add_argument("--repo", default="EIGHTfs/DeepSeekHarness-NAS",
                        help="被服务的 GitHub 仓库（owner/repo）；换仓库无需改脚本")
    parser.add_argument("--tag", default="latest", help="指定 Release tag，缺省 latest")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--interval", type=int, default=1800, help="刷新间隔秒（缺省 1800）")
    parser.add_argument("--arches", nargs="*", default=[], help="只处理指定架构（x86_64 / armv8）")
    parser.add_argument("--out-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pkg-source"))
    parser.add_argument("--work-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pkg-source", "spk"))
    parser.add_argument("--from-spk-dir", default="", help="离线模式：直接读本地 spk 目录")
    parser.add_argument("--base-url", default="", help="离线模式下写入 link 的前缀")
    parser.add_argument("--with-md5", action="store_true",
                        help="下载 spk 计算 md5（默认不下载：下载由套件中心自己做；缺 md5 时 DSM 不做校验）")
    parser.add_argument("--deep", action="store_true",
                        help="下载 spk 读 INFO 取准确 package/version/changelog（默认取资产名里的版本）")
    parser.add_argument("--once", action="store_true", help="生成一次即退出（cron 用）")
    parser.add_argument("--check", action="store_true", help="只生成并打印，不起服务")
    args = parser.parse_args()

    args.out_dir = os.path.abspath(args.out_dir)
    args.work_dir = os.path.abspath(args.work_dir)
    os.makedirs(args.work_dir, exist_ok=True)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

    ok = refresh(args, token)
    if args.check or args.once:
        return 0 if ok else 2
    if not ok:
        log("首次生成失败；服务仍会启动（DSM 看到 503），下次刷新成功后自动恢复")

    Handler.state["out_dir"] = args.out_dir
    server = ThreadingHTTPServer((args.bind, args.port), Handler)

    def loop():
        while True:
            time.sleep(max(60, args.interval))
            refresh(args, token)

    threading.Thread(target=loop, daemon=True).start()

    host = lan_ip()
    log("套件源就绪（仓库 %s）。DSM 套件中心 → 设置 → 套件来源 添加：" % args.repo)
    for arch in (args.arches or ["x86_64", "armv8"]):
        log("  %-7s → http://%s:%d/index-%s.json" % (arch, host, args.port, arch))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("收到中断，退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
