#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-native-entity.py — 出货闸：白名单点名的「本架构必需原生包」必须在载荷里有实体。

为什么需要（实测事故）：
  armv8 包曾经"能打包、能安装、各项校验全过"，但装完 DSH 起不来。原因是载荷里
  `node-addon-require-builtin-linux-arm64-gnu` 只有**指向不存在目录的软链**，
  真正的 `.node` 二进制根本没打进去。软链在 tar 里是合法条目，所以按"路径条目数"
  做的检查完全看不出来（当时就是这么漏的）。
  运行期表现：boot 入口 require 该包 → Cannot find module → 进程退出 code=1，
  **完全无法启动**，而套件中心可能仍显示"已启动"。

判据（精准，不误伤可选依赖）：
  裁剪白名单里那些**平台专属条目**（形如 `xxx-linux-{arch}`）声明了"本架构必需哪些
  原生包"。本闸把它们按目标架构展开，逐个断言载荷里存在**实体**（非软链、非空目录）：
    · `node-addon-require-builtin-linux-<arch>-gnu` → 找 .pnpm 下该包目录且有 .node
    · `@img/sharp-linux-<arch>` 等 → 同上
    · `@deepseek-ai/node-addon-system-linux-<arch>` → 对应 native/system/packages/linux-<arch>/
  为什么不用"所有软链都必须存在"：pnpm 会为 optionalDependencies 留软链，裁剪后必然
  悬空（musl 变体、其它平台的 CLI 二进制等），那些悬空不影响运行，判失败会天天误报。

用法：
  ./scripts/guards/check-native-entity.py <包.spk|包.fpk> --arch x86_64|arm64 [--verbose]
退出码：0 通过；1 不合格；2 用法/读取错误
"""
from __future__ import print_function

import json
import os
import posixpath
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WHITELIST = os.path.join(ROOT, "build", "config", "build-prune-whitelist.json")

ARCH_LABEL = {"x86_64": "x64", "arm64": "arm64", "armv8": "arm64"}
NATIVE_DIR_TAG = {"x86_64": "linux-x64", "arm64": "linux-arm64", "armv8": "linux-arm64"}
INNER_CANDIDATES = ("package.tgz", "app.tgz")


def required_native_packages(arch):
    """从裁剪白名单推导「本架构必需的原生包」清单（跳过 musl：目标是 glibc）。"""
    with open(WHITELIST, encoding="utf-8") as handle:
        data = json.load(handle)
    label = ARCH_LABEL[arch]
    wanted = []
    for key in ("lockfileDeps", "extra", "_autoLearned"):
        for entry in data.get(key) or []:
            if not isinstance(entry, str) or "{arch}" not in entry:
                continue
            name = entry.replace("{arch}", label)
            if "musl" in name:      # musl 变体在 glibc 目标上不需要
                continue
            if name not in wanted:
                wanted.append(name)
    return wanted


def open_payload(path):
    """打开包的内层载荷（SPK: package.tgz / FPK: app.tgz），返回 (tarfile, 临时文件路径)。"""
    outer = tarfile.open(path, "r:*")
    for member in outer.getmembers():
        if posixpath.basename(member.name) in INNER_CANDIDATES and member.isfile():
            handle = outer.extractfile(member)
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".tgz")
            tmp.write(handle.read())
            tmp.close()
            outer.close()
            return tarfile.open(tmp.name, "r:gz"), tmp.name
    outer.close()
    raise RuntimeError("包内未找到 %s" % " / ".join(INNER_CANDIDATES))


def scan(inner, arch):
    """收集：.pnpm 下每个包目录的实体文件数、native/system 平台目录内容。"""
    label = ARCH_LABEL[arch]
    dir_tag = NATIVE_DIR_TAG[arch]
    pnpm_entities = {}     # 包名 → 实体文件数（size>0）
    native_dir_files = 0
    for member in inner.getmembers():
        name = member.name.lstrip("./")
        if member.isfile() and member.size > 0:
            # .pnpm/<包名>@<版本>/... → 取包名（+ 版本分隔符）
            if name.startswith("node_modules/.pnpm/"):
                rest = name[len("node_modules/.pnpm/"):]
                head = rest.split("/", 1)[0]
                # .pnpm 目录名把 scope 的 "/" 写成 "+"（@img/sharp-linux-arm64 → @img+sharp-linux-arm64@1.0.0），
                #   且可能带 peer 后缀（pkg@1.0.0_peer@2.0.0）。必须还原成真实包名再比对，
                #   否则所有带 scope 的平台包都会误判成"没有实体"（实测踩到）。
                base = head.split("_")[0]
                if base.startswith("@"):
                    pkg = base.rpartition("@")[0]
                else:
                    pkg = base.partition("@")[0]
                pkg = pkg.replace("+", "/")
                pnpm_entities[pkg] = pnpm_entities.get(pkg, 0) + 1
            if ("native/system/packages/%s/" % dir_tag) in name:
                native_dir_files += 1
    return pnpm_entities, native_dir_files


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    verbose = "--verbose" in sys.argv
    arch = ""
    if "--arch" in sys.argv:
        index = sys.argv.index("--arch")
        arch = sys.argv[index + 1] if len(sys.argv) > index + 1 else ""
    if not args or arch not in ARCH_LABEL:
        print("用法: check-native-entity.py <包.spk|包.fpk> --arch x86_64|arm64 [--verbose]")
        return 2
    package = args[0]
    if not os.path.isfile(package):
        print("✗ 包不存在：%s" % package)
        return 2

    print("▶ 出货闸：%s（架构 %s）" % (os.path.basename(package), arch))
    wanted = required_native_packages(arch)
    if not wanted:
        print("✗ 白名单里没有 {arch} 平台条目 —— 无法判定必需原生包（白名单被改坏？）")
        return 1

    inner, tmp_path = open_payload(package)
    try:
        pnpm_entities, native_dir_files = scan(inner, arch)
    finally:
        inner.close()
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    problems = []
    for name in wanted:
        # native/system 是打包器按架构放的特殊目录，不在 .pnpm 里
        if "node-addon-system" in name:
            if native_dir_files > 0:
                if verbose:
                    print("  ✓ %-52s native/system 下 %d 个文件" % (name, native_dir_files))
                continue
            problems.append("%s：native/system/packages/%s 下没有实体文件"
                            % (name, NATIVE_DIR_TAG[arch]))
            continue
        count = pnpm_entities.get(name, 0)
        if count > 0:
            if verbose:
                print("  ✓ %-52s 实体文件 %d 个" % (name, count))
        else:
            problems.append("%s：包内没有实体（软链悬空或整包被裁掉）" % name)

    if problems:
        print("✗ 不合格（%d 项）：" % len(problems))
        for item in problems:
            print("   %s" % item)
        print("   后果：装上去 DSH 启动即 Cannot find module → 进程退出 code=1，完全无法启动")
        print("   修复：确认该架构走的是完整构建（会跑 fix-runtime-deps 补包），"
              "不要让缓存 target 复用跳过补包")
        return 1
    print("✓ 通过：%d 个本架构必需原生包都有实体" % len(wanted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
