#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-release-assets.py — 发布后核对某个官方 tag 的 Release 是否「四资产齐套」。

为什么需要：
  构建按架构分开跑（x86_64 与 arm64 各一次 workflow run），两个 run 各自把自己的产物
  发到**同一个 tag** 的 Release。只要其中一个架构失败，那个 Release 就永久只有一半资产
  （例如只有 armv8 spk + arm fpk，缺 x86_64 spk + x86 fpk），下载者会拿到装不上的包，
  而两次 run 的 job 结论看上去都没问题（成功那次是绿的）。

  所以发布后要有一道「四件是否齐全」的独立核对：缺件时说清楚缺哪几件。

用法：
  python3 scripts/guards/check-release-assets.py --repo owner/name --tag dsh-v<版本> [--token TOKEN]
  python3 scripts/guards/check-release-assets.py --repo owner/name --tag dsh-v<版本> --strict   # 缺件返回 1
  python3 scripts/guards/check-release-assets.py --repo owner/name --tag dsh-v<版本> --json

退出码：
  0  四件齐全；或不齐但未加 --strict（只告警）
  1  缺件且加了 --strict
  2  取不到 Release（网络/凭据/tag 不存在）
"""
from __future__ import print_function

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

# 四件期望产物：后缀固定，前缀（包名）允许任意，便于改包名后仍可用
EXPECTED = [
    ("x86_64 spk", re.compile(r"_x86_64-(?P<ver>.+)\.spk$")),
    ("armv8 spk", re.compile(r"_armv8-(?P<ver>.+)\.spk$")),
    ("x86 fpk", re.compile(r"_x86-(?P<ver>.+)\.fpk$")),
    ("arm fpk", re.compile(r"_arm-(?P<ver>.+)\.fpk$")),
]


def fetch_release(repo, tag, token):
    """取指定 tag 的 Release；返回 (release_dict, None) 或 (None, 错误说明)。"""
    url = "https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag)
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    if token:
        req.add_header("Authorization", "token %s" % token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None, "Release 不存在（tag=%s）" % tag
        return None, "HTTP %s（网络或限流；传 --token 可提高配额）" % exc.code
    except Exception as exc:  # 网络类异常一律归为取不到
        return None, "请求失败：%s" % exc


def classify(assets, version):
    """把实际资产按四类归档；返回 {类别: [资产名...]}（只收该版本号的）。"""
    found = {label: [] for label, _ in EXPECTED}
    for asset in assets:
        name = asset.get("name") or ""
        for label, pattern in EXPECTED:
            m = pattern.search(name)
            if not m:
                continue
            # 资产名里的版本必须与 tag 版本一致，避免把别的版本算进来
            if version and m.group("ver") != version:
                continue
            found[label].append(name)
            break
    return found


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--tag", required=True, help="官方 tag，如 dsh-v0.2.3-alpha.2")
    ap.add_argument("--token", default="", help="GitHub token（也可用 GH_TOKEN / GITHUB_TOKEN 环境变量）")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--strict", action="store_true", help="缺件时返回 1（默认只告警）")
    args = ap.parse_args()

    token = args.token or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    version = args.tag[5:] if args.tag.startswith("dsh-v") else args.tag

    release, err = fetch_release(args.repo, args.tag, token)
    if release is None:
        payload = {"tag": args.tag, "ok": False, "error": err}
        if args.json:
            print(json.dumps(payload, ensure_ascii=False))
        else:
            print("✗ %s" % err, file=sys.stderr)
        return 2

    found = classify(release.get("assets") or [], version)
    missing = [label for label, _ in EXPECTED if not found[label]]

    payload = {
        "tag": args.tag,
        "version": version,
        "ok": not missing,
        "missing": missing,
        "found": found,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print("═══ Release 资产齐套检查：%s ═══" % args.tag)
        for label, _ in EXPECTED:
            names = found[label]
            mark = "✓" if names else "✗"
            print("  %s %-12s %s" % (mark, label, names[0] if names else "（缺失）"))
        if missing:
            print("")
            print("⚠ 缺 %d 件：%s" % (len(missing), "、".join(missing)))
            print("  同一 tag 需要两个架构各跑一次构建才能凑齐四件；缺的那次请单独重跑对应 arch。")
        else:
            print("")
            print("✓ 四件齐全")

    if missing and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
