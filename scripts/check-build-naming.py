#!/usr/bin/env python3
"""check-build-naming.py — 命名规范守卫（job / action / 脚本）

规范（2026-10-04 定，步骤 12 的改名会进一步收紧）：
  · CI job      ：`<动词>-<产物>[-<链路>]`，动词 ∈ {build, pack, release}
  · 复合 action ：`.github/actions/<kebab-case>`
  · 构建脚本    ：`build/build-<角色>.sh`（公共/编排）
                  `build/<FMT>/<pack|build>-<小写>.sh`（FMT ∈ SPK/FPK）
  · scripts/    ：`<kebab-case>.sh|.py`

用法：python3 scripts/check-build-naming.py [--list]
退出码：0 通过 / 1 违规
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows", "build.yml")
VERBS = ("build", "pack", "release")
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
JOB = re.compile(r"^  ([a-z0-9-]+):\s*$", re.M)


def main():
    v = []
    listing = []

    # 1) CI job 名
    if os.path.isfile(WF):
        text = open(WF, encoding="utf-8").read()
        # 只取 jobs: 块（否则会把 on: 下的 schedule/push 等 YAML 键误当 job）
        ji = text.find("\njobs:")
        block = text[ji + 1:] if ji != -1 else ""
        end = block.find("\n\n", block.find("jobs:"))
        if end != -1:
            block = block[:end]
        for m in JOB.finditer(block):
            name = m.group(1)
            if name in ("jobs", "steps", "env", "with", "strategy", "matrix"):
                continue
            verb = name.split("-")[0]
            if verb not in VERBS:
                v.append("build.yml job `%s` 动词不在 %s 中（规范 <动词>-<产物>[-<链路>]）" % (name, list(VERBS)))
            elif not KEBAB.match(name):
                v.append("build.yml job `%s` 不是 kebab-case" % name)
            else:
                listing.append("job: " + name)

    # 2) 复合 action 目录名
    adir = os.path.join(ROOT, ".github", "actions")
    if os.path.isdir(adir):
        for d in sorted(os.listdir(adir)):
            if os.path.isdir(os.path.join(adir, d)):
                if not KEBAB.match(d):
                    v.append(".github/actions/%s 不是 kebab-case" % d)
                else:
                    listing.append("action: " + d)

    # 3) 构建脚本
    bdir = os.path.join(ROOT, "build")
    for f in sorted(os.listdir(bdir)):
        if f.endswith(".sh"):
            if not KEBAB.match(f.rsplit(".", 1)[0]):
                v.append("build/%s 不是 kebab-case 命名" % f)
            else:
                listing.append("script: build/" + f)
    for fmt in ("SPK", "FPK"):
        fd = os.path.join(bdir, fmt)
        if not os.path.isdir(fd):
            continue
        for f in sorted(os.listdir(fd)):
            if not f.endswith(".sh"):
                continue
            if not re.match(r"^(pack|build)-[a-z0-9-]+\.sh$", f):
                v.append("build/%s/%s 应命名为 pack-<格式>.sh 或 build-<角色>.sh" % (fmt, f))
            else:
                listing.append("script: build/%s/%s" % (fmt, f))

    # 3.5) .sh / .py 必须带可执行位（2026-10-04 实测踩坑：release-note.sh 是 644，
    #      CI 里 ./build/release-note.sh 直接 Permission denied（exit 126），
    #      导致 SPK/FPK 已成功打出、却在生成 Release 文案时失败。
    import subprocess as _sp
    try:
        _out = _sp.run(["git", "ls-files", "-s", "*.sh", "*.py"], cwd=ROOT,
                       capture_output=True, text=True, timeout=30)
        if _out.returncode == 0:
            for _ln in _out.stdout.splitlines():
                _mode, _path = _ln.split(None, 1)[0], _ln.split(None, 3)[-1]
                if _path.startswith("tools/"):
                    continue   # vendored 第三方（pnpm 发行包内的脚本），不要求可执行位
                if _mode != "100755":
                    v.append("%s 缺少可执行位（%s）—— CI 里以 ./ 调用会 Permission denied" % (_path, _mode))
    except Exception:
        pass

    # 4) scripts/ 下的 kebab-case
    sdir = os.path.join(ROOT, "scripts")
    for base, dirs, files in os.walk(sdir):
        dirs[:] = [d for d in dirs if d != "lib"]
        for f in sorted(files):
            if not f.endswith((".sh", ".py")):
                continue
            stem = f.rsplit(".", 1)[0]
            if not KEBAB.match(stem):
                v.append("%s 不是 kebab-case 命名" % os.path.relpath(os.path.join(base, f), ROOT))
            else:
                listing.append("script: " + os.path.relpath(os.path.join(base, f), ROOT))

    if "--list" in sys.argv:
        for x in listing:
            print("  " + x)
    if v:
        print("✗ 命名守卫失败（%d 项）：" % len(v))
        for x in v:
            print("   - " + x)
        return 1
    print("✓ 命名守卫通过（job/action/脚本 共 %d 项符合规范）" % len(listing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
