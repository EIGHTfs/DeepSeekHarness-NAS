#!/usr/bin/env python3
#===============================================================================
# scripts/gh-commit.py — 不依赖工作区写权限的原子提交推送（GitHub Git Data API）
#
# 【它解决什么问题】
#   blobs → tree → commit → 更新 ref，全程走 GitHub REST API，**只需要能读到文件内容**，
#   不需要在本机拥有可用的 git 二进制，也不需要对该仓库目录有写权限。
#
# 【当初为什么写它（历史背景，条件已变，保留以便理解设计取舍）】
#   当时本机对工作区无权限、sudo 密码未知，而另一台机器（.193）的 git 包已损坏
#   （/var/packages/git/target → /volume1/@appstore/git 内容被删），两条常规路子都走不通。
#   ⚠ 现在这两个前提**都不再成立**：工作区已授权可写，本机 /bin/git（2.39.1）可用。
#   因此本脚本的定位从"唯一出路"变为"**备用通道**"：
#     · 常规提交推送请优先用 git（更快、有完整钩子与 diff 视图）；
#     · 当 git 不可用/无写权限/需要一次性原子提交多文件时，再用本脚本。
#
# 【特点】
#   · 不需要 git 二进制、不需要工作区写权限（读文件即可）
#   · **原子多文件提交**（一次 commit 覆盖全部改动）
#   · author/committer 固定为 EIGHTfs（用户口径）
#   · 快进失败（远端有新提交）时自动重取 HEAD 重试
#
# 【用法】
#   python3 scripts/gh-commit.py <仓库根目录> "<提交信息>" <文件1> [文件2 ...]
#   例：python3 scripts/gh-commit.py "/volume13/.../DeepSeekHarness-NAS" "feat: x" scripts/lib/common.sh
#
# 【token 来源】见下方 token()：优先环境变量 GH_TOKEN / GITHUB_TOKEN，其次读本文件所在仓库
#   同级的 config.json 的 githubToken 字段（该文件由用户维护，不入库）。
#===============================================================================
import base64, json, os, sys, time, urllib.request, urllib.error

OWNER, REPO, BRANCH = "EIGHTfs", "DeepSeekHarness-NAS", "main"
AUTHOR_NAME = "EIGHTfs"
AUTHOR_EMAIL = "EIGHTfs@users.noreply.github.com"


def token():
    """取 GitHub token：先环境变量，再依次尝试若干候选 config.json。

    候选路径按"当前真实布局"优先排列（早期写死过 /volume1/VirtualDSM/... 的旧路径，
    该路径现已不存在；写死单一路径会让脚本在目录搬迁后静默失效，故改为候选列表 + 明确报错）。
    """
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = [
        os.environ.get("DSH_GIT_PUSH_CONFIG", ""),
        os.path.join(os.path.dirname(repo_root), "config.json"),          # 工作区/config.json（用户维护）
        "/volume13/Artificial Intelligence/DeepSeek/DeepSeekHarness/工作区/config.json",
        "/volume1/VirtualDSM/DeepSeekHarness/.dsh/git-push/config.json",  # 历史路径（可能已不存在）
    ]
    tried = []
    for path in candidates:
        if not path:
            continue
        tried.append(path)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                tok = (json.load(f).get("githubToken") or "").strip()
        except Exception as e:
            sys.stderr.write("⚠ 读取 %s 失败：%s\n" % (path, e))
            continue
        if tok:
            return tok
    sys.stderr.write(
        "✗ 未找到 githubToken。请设置 GH_TOKEN / GITHUB_TOKEN 环境变量，"
        "或把含 githubToken 的 config.json 放到下列任一位置：\n  - "
        + "\n  - ".join([p for p in tried if p]) + "\n")
    raise SystemExit(2)


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
