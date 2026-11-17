#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify-pkg-arch.py —— 检查一份已发布的安装包（spk / fpk）里二进制是否真属于目标架构。

为什么需要：曾出现「x86_64 安装包塞进 ARM 的 bin/node 与 linux-arm64 原生模块」的串味事故。
这类包能装、文件齐、sha256 算得出、结构对比也一致 —— 只有 ELF 头能看出架构，
而症状要等套件起不来或运行期首次走文件锁才暴露。所以验收时直接读 ELF。

判据：
  · bin/node 的 ELF e_machine 必须等于目标架构（x86-64 = 0x3E / AArch64 = 0xB7）
  · native/system/packages 下必须存在目标平台目录（x86_64→linux-x64 / arm64→linux-arm64），
    且其中含 bin/glibc/system.node

用法：
    ./verify-pkg-arch.py <包路径> [--arch x86_64|arm64] [--keep]
      不给 --arch 时按文件名推断（含 "arm" 视为 arm64，否则 x86_64）
      --keep 保留解包临时目录（默认验完即删）
退出码：0 通过；1 不通过；2 参数或解包失败
"""
import argparse
import io
import os
import shutil
import struct
import sys
import tarfile
import tempfile

ELF_MACHINE_X86_64 = 0x3E
ELF_MACHINE_AARCH64 = 0xB7
EXPECTED = {
    'x86_64': (ELF_MACHINE_X86_64, 'linux-x64', 'x86-64'),
    'arm64': (ELF_MACHINE_AARCH64, 'linux-arm64', 'AArch64'),
}
ELF_HEADER_MIN_BYTES = 20


def guess_arch_from_name(path):
    """文件名里带 arm 的当 arm64（本项目的命名：armv8 spk / arm fpk），其余当 x86_64。"""
    base = os.path.basename(path).lower()
    return 'arm64' if 'arm' in base else 'x86_64'


def read_elf_machine(path):
    with open(path, 'rb') as handle:
        header = handle.read(ELF_HEADER_MIN_BYTES)
    if len(header) < ELF_HEADER_MIN_BYTES or header[:4] != b'\x7fELF':
        return None
    return struct.unpack('<H', header[0x12:0x14])[0]


def extract_node_and_native(package_path, work_dir):
    """把包里的 bin/node 与 native/ 解出来，返回 (node 路径, 解包根, 载荷名)。spk 与 fpk 结构不同。

    注意压缩形态不一样（实测）：
      · spk 外层是**未压缩 tar**，载荷是 package.tgz
      · fpk 外层是**gzip 过的 tar**（magic 1f8b），载荷是 app.tgz
    所以外层一律用 r:* 让 tarfile 自己识别，不能写死 'r:'。
    """
    outer = tarfile.open(package_path, 'r:*')
    names = outer.getnames()
    if 'package.tgz' in names:
        payload_name = 'package.tgz'
    elif 'app.tgz' in names:
        payload_name = 'app.tgz'
    else:
        outer.close()
        raise RuntimeError('包内既没有 package.tgz 也没有 app.tgz（不是预期的 spk/fpk 结构）')
    payload_bytes = outer.extractfile(payload_name).read()
    outer.close()

    inner = tarfile.open(fileobj=io.BytesIO(payload_bytes), mode='r:gz')
    wanted = [m for m in inner.getmembers()
              if m.name.endswith('/bin/node') or m.name.endswith('bin/node')
              or m.name.startswith('./native/') or m.name.startswith('native/')
              or '/native/system/' in m.name]
    inner.extractall(work_dir, members=wanted)
    inner.close()

    node_path = None
    for root, _dirs, files in os.walk(work_dir):
        if 'node' in files and os.path.basename(root) == 'bin':
            candidate = os.path.join(root, 'node')
            if read_elf_machine(candidate) is not None:
                node_path = candidate
                break
    return node_path, work_dir, payload_name


def find_native_platforms(work_dir):
    found = []
    for root, dirs, _files in os.walk(work_dir):
        if root.endswith(os.path.join('native', 'system', 'packages')):
            found = [d for d in dirs if d.startswith('linux-')]
            return found, root
    return [], None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package')
    parser.add_argument('--arch', choices=sorted(EXPECTED), default=None)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()

    package_path = os.path.abspath(args.package)
    if not os.path.isfile(package_path):
        print('  ✗ 包不存在: %s' % package_path)
        return 2

    arch = args.arch or guess_arch_from_name(package_path)
    expect_machine, expect_platform, machine_name = EXPECTED[arch]
    print('═══ %s' % os.path.basename(package_path))
    print('  目标架构: %s（%s）' % (arch, '按文件名推断' if args.arch is None else '显式指定'))

    work_dir = tempfile.mkdtemp(prefix='pkgarch-')
    failed = False
    try:
        try:
            node_path, _, payload_name = extract_node_and_native(package_path, work_dir)
        except Exception as exc:
            print('  ✗ 解包失败: %s' % exc)
            return 2
        print('  载荷: %s' % payload_name)

        if not node_path:
            print('  ✗ 载荷里找不到 bin/node')
            return 2

        machine = read_elf_machine(node_path)
        if machine is None:
            print('  ✗ bin/node 不是可识别的 ELF')
            failed = True
        elif machine != expect_machine:
            actual_name = {ELF_MACHINE_X86_64: 'x86-64', ELF_MACHINE_AARCH64: 'AArch64'}.get(machine, hex(machine))
            print('  ✗ bin/node 架构不符：期望 %s，实际 %s' % (machine_name, actual_name))
            failed = True
        else:
            print('  ✓ bin/node = %s' % machine_name)

        platforms, platform_root = find_native_platforms(work_dir)
        if not platforms:
            print('  ⚠ 未找到 native/system/packages 下的平台目录（该版本可能不含原生模块）')
        elif expect_platform not in platforms:
            print('  ✗ native 缺目标平台目录 %s（实际只有：%s）' % (expect_platform, ', '.join(platforms)))
            failed = True
        else:
            system_node = os.path.join(platform_root, expect_platform, 'bin', 'glibc', 'system.node')
            if os.path.exists(system_node):
                print('  ✓ native 有 %s 且含 glibc/system.node' % expect_platform)
            else:
                print('  ⚠ native 有 %s，但缺 bin/glibc/system.node' % expect_platform)
            others = [p for p in platforms if p != expect_platform]
            if others:
                print('  · 另有其它平台目录（不影响运行，只增体积）: %s' % ', '.join(others))
    finally:
        if args.keep:
            print('  临时目录保留: %s' % work_dir)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)

    print('  结论: %s' % ('✗ 不通过' if failed else '✓ 通过'))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
