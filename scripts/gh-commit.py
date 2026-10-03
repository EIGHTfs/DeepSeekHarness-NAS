#!/usr/bin/env python3
#===============================================================================
# /tmp/gh_commit.py — 无 git 的原子提交推送（GitHub Git Data API）
#
# 背景（2026-10-04）：
#   本机（.64）对工作区无权限、sudo 密码未知；.193 的 git 包已损坏
#   （/var/packages/git/target → /volume1/@appstore/git 内容被删）。
#   故改用 GitHub API 直接提交：blobs → tree → commit → 更新 ref。
#
# 特点：
#   · 不需要 git 二进制、不需要工作区写权限（读文件即可）
#   · **原子多文件提交**（一次 commit 覆盖全部改动）
#   · author/committer 固定为 EIGHTfs（用户 2026-10-04 口径）
#   · 快进失败（远端有新提交）时自动重取 HEAD 重试
#
# 用法：
#   python3 /tmp/gh_commit.py <仓库根目录> "<提交信息>" <文件1> [文件2 ...]
#   例：python3 /tmp/gh_commit.py "/volume13/.../DeepSeekHarness-NAS" "feat: x" scripts/lib/common.sh
#===============================================================================
import base64, json, os, sys, time, urllib.request, urllib.error

OWNER, REPO, BRANCH = "EIGHTfs", "DeepSeekHarness-NAS", "main"
AUTHOR_NAME = "EIGHTfs"
AUTHOR_EMAIL = "EIGHTfs@users.noreply.github.com"
CONFIG = "/volume1/VirtualDSM/DeepSeekHarness/.dsh/git-push/config.json"


def token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    with open(CONFIG, encoding="utf-8") as f:
        return json.load(f)["githubToken"].strip()


def api(path, method="GET", payload=None, tok=None):
    url = "https://api.github.com" + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read().decode() or "{}"
                return json.loads(body)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:300]
            if e.code in (409, 422) and attempt < 2:
                time.sleep(2)
                continue
            raise RuntimeError("HTTP %s %s %s -> %s" % (e.code, method, path, detail))
        except Exception:
            if attempt < 2:
                time.sleep(3)
                continue
            raise


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    root, message = sys.argv[1], sys.argv[2]
    files = sys.argv[3:]
    tok = token()

    for f in files:
        if not os.path.isfile(os.path.join(root, f)):
            print("✗ 文件不存在: %s" % f)
            return 1

    for attempt in range(4):
        ref = api("/repos/%s/%s/git/ref/heads/%s" % (OWNER, REPO, BRANCH), tok=tok)
        head = ref["object"]["sha"]
        base_commit = api("/repos/%s/%s/git/commits/%s" % (OWNER, REPO, head), tok=tok)
        base_tree = base_commit["tree"]["sha"]

        entries = []
        for f in files:
            raw = open(os.path.join(root, f), "rb").read()
            blob = api("/repos/%s/%s/git/blobs" % (OWNER, REPO), "POST",
                       {"content": base64.b64encode(raw).decode(), "encoding": "base64"}, tok=tok)
            entries.append({"path": f, "mode": "100755" if f.endswith(".sh") else "100644",
                            "type": "blob", "sha": blob["sha"]})

        tree = api("/repos/%s/%s/git/trees" % (OWNER, REPO), "POST",
                   {"base_tree": base_tree, "tree": entries}, tok=tok)
        commit = api("/repos/%s/%s/git/commits" % (OWNER, REPO), "POST",
                     {"message": message, "tree": tree["sha"], "parents": [head],
                      "author": {"name": AUTHOR_NAME, "email": AUTHOR_EMAIL},
                      "committer": {"name": AUTHOR_NAME, "email": AUTHOR_EMAIL}}, tok=tok)
        try:
            api("/repos/%s/%s/git/refs/heads/%s" % (OWNER, REPO, BRANCH), "PATCH",
                {"sha": commit["sha"], "force": False}, tok=tok)
        except RuntimeError as e:
            if "422" in str(e) or "409" in str(e):
                print("  ↻ 远端已前进，重取 HEAD 重试（%d/4）" % (attempt + 1))
                continue
            raise
        print("  ✓ 已推送 %s -> %s" % (commit["sha"][:7], BRANCH))
        print("    author: %s <%s>" % (AUTHOR_NAME, AUTHOR_EMAIL))
        print("    文件: %s" % ", ".join(files))
        return 0
    print("✗ 连续冲突，放弃")
    return 1


if __name__ == "__main__":
    sys.exit(main())
