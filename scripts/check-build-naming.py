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

# yml 里出现的脚本引用：scripts/xxx.sh、./build/xxx.sh、test/xxx.py 等
SCRIPT_REFERENCE = re.compile(r'(?:^|[\s"\'(`])((?:\./)?(?:scripts|build|test)/[A-Za-z0-9._/-]+\.(?:sh|py))')
JOB = re.compile(r"^  ([a-z0-9-]+):\s*$", re.M)


def _check_jobs(v, listing):
    """① CI job 名必须是 <动词>-<产物>[-<链路>] 且 kebab-case。

    只取 `jobs:` 块：否则 `on:` 下的 schedule/push 等 YAML 键会被正则误当成 job 名。
    """
    if not os.path.isfile(WF):
        return
    text = open(WF, encoding="utf-8").read()
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


def _check_actions(v, listing):
    """② .github/actions/<目录名> 必须是 kebab-case（它就是 action 的对外名字）。"""
    adir = os.path.join(ROOT, ".github", "actions")
    if not os.path.isdir(adir):
        return
    for d in sorted(os.listdir(adir)):
        if not os.path.isdir(os.path.join(adir, d)):
            continue
        if not KEBAB.match(d):
            v.append(".github/actions/%s 不是 kebab-case" % d)
        else:
            listing.append("action: " + d)


def _check_build_scripts(v, listing):
    """③ build/ 与其下 SPK/FPK 的脚本命名：build/ 用 kebab-case，
    SPK/FPK 里只允许 pack-<格式>.sh 或 build-<角色>.sh
    （此规则是为了防止再次出现历史上那种 `build-<产物>.sh` 式的旧命名）。"""
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


def _tracked_paths():
    """当前 git 索引里的全部路径（取不到就返回空列表）。"""
    import subprocess as sp
    try:
        out = sp.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    return [line for line in out.stdout.split("\n") if line]


def _build_chain_scripts():
    """构建链路真正会执行到的脚本集合。

    为什么需要这个边界：本守卫原来对「全仓所有 .sh/.py」要求可执行位与语法，于是
    scripts/ 下的运维、诊断、探活类脚本（与构建毫无关系）只要缺一个 +x，整条构建就被拦下 ——
    构建连 build-target 都没进。构建门卫只该管「构建会跑到的东西」。

    集合来源只有两类事实，不含白名单：
      ① build/ 与 test/ 下的脚本本身就是构建/测试链路；
      ② workflow 与复合 action 的 yml 里显式出现的 scripts/ 路径（守卫脚本自己被
         build.yml 调用，所以仍会被检查）。
    """
    import glob
    import subprocess as sp  # noqa: F401  （与其它子检查保持同样的导入风格）

    chain = set()
    for path in _tracked_paths():
        if path.startswith(("build/", "test/")) and path.endswith((".sh", ".py")):
            chain.add(path)

    yaml_patterns = (".github/workflows/*.yml", ".github/actions/*/action.yml")
    for pattern in yaml_patterns:
        for yml_path in glob.glob(os.path.join(ROOT, pattern)):
            try:
                with open(yml_path, encoding="utf-8") as handle:
                    content = handle.read()
            except OSError:
                continue
            for match in SCRIPT_REFERENCE.finditer(content):
                candidate = match.group(1)
                if candidate.startswith("./"):
                    candidate = candidate[2:]
                chain.add(candidate)
    return chain


def _check_exec_bits(v):
    """④ .sh / .py 必须带可执行位。

    踩坑实录：build/release-note.sh 在仓库里是 644，CI 里 `./build/release-note.sh`
    直接 Permission denied（exit 126）—— 当时 SPK/FPK 都已成功打出，却在生成 Release
    文案时整条流水线失败。故在此断言；vendored 的 tools/ 不参与（第三方脚本不要求）。
    """
    import subprocess as sp
    build_chain = _build_chain_scripts()
    try:
        out = sp.run(["git", "ls-files", "-s"], cwd=ROOT,
                     capture_output=True, text=True, timeout=60)
    except Exception:
        return
    if out.returncode != 0:
        return
    for ln in out.stdout.splitlines():
        parts = ln.split(None, 3)
        if len(parts) < 4:
            continue
        mode, path = parts[0], parts[3]
        if path.startswith("tools/"):
            continue
        if path not in build_chain:
            continue
        if mode != "100755":
            v.append("%s 缺少可执行位（%s）—— CI 里以 ./ 调用会 Permission denied" % (path, mode))


def _check_syntax(v):
    """⑤ 全部 .sh 跑 `bash -n`、全部 .py 跑 `ast.parse`（排除 vendored tools/）。

    加这一项的原因：审核时发现 scripts/diagnose/dsh-plugin-install-fix.sh 因多写一个引号
    而 `bash -n` 失败，但当时的守卫套件不做语法检查，导致这个坏脚本长期留在仓库里没人发现。
    """
    import subprocess as sp
    build_chain = _build_chain_scripts()
    sh_targets = [f for f in build_chain if f.endswith(".sh") and f.startswith(("scripts/", "build/", "test/"))]
    py_targets = [f for f in build_chain if f.endswith(".py") and f.startswith(("scripts/", "build/", "test/"))]
    if True:
        for f in sh_targets:
            r = sp.run(["bash", "-n", f], cwd=ROOT, capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                first = (r.stderr or "").strip().splitlines()
                v.append("%s 语法错误（bash -n）：%s" % (f, first[0][:90] if first else "?"))
    if True:
        for f in py_targets:
            r = sp.run(["python3", "-c", "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())", f],
                       cwd=ROOT, capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                last = (r.stderr or "").strip().splitlines()
                v.append("%s 语法错误（ast）：%s" % (f, last[-1][:90] if last else "?"))


def _check_script_names(v, listing):
    """⑥ scripts/ 下（含子目录，跳过 lib/）的 .sh/.py 必须是 kebab-case。

    lib/ 例外：它是公共库的固定落点（scripts/lib/common.sh），文件名有既有约定，不参与本规则。
    """
    sdir = os.path.join(ROOT, "scripts")
    for base, dirs, files in os.walk(sdir):
        dirs[:] = [d for d in dirs if d != "lib"]
        for f in sorted(files):
            if not f.endswith((".sh", ".py")):
                continue
            stem = f.rsplit(".", 1)[0]
            rel = os.path.relpath(os.path.join(base, f), ROOT)
            if not KEBAB.match(stem):
                v.append("%s 不是 kebab-case 命名" % rel)
            else:
                listing.append("script: " + rel)


def main():
    """命名/权限/语法守卫入口：逐项收集问题，最后一次性报告。

    拆成 6 个子检查（job / action / build 脚本 / 可执行位 / 语法 / scripts 命名）而不是
    堆在一个函数里，是为了让失败信息能对应到明确的一项，便于定位（本函数此前已长到 100+ 行）。
    """
    v = []
    listing = []
    _check_jobs(v, listing)
    _check_actions(v, listing)
    _check_build_scripts(v, listing)
    _check_exec_bits(v)
    _check_syntax(v)
    _check_script_names(v, listing)

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
