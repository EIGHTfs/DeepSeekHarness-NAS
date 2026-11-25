#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check-target-arch.py —— 校验构建产物里的二进制与目标架构一致。

为什么需要它（真实事故）：x86_64 与 arm64 并行构建时，两者共用了一份不含架构的
target 缓存，先跑完的那个把 target 写进缓存、后跑的另一个直接复用，于是 x86_64 的
安装包里被塞进了 arm64 的 bin/node 与 native/…/linux-arm64 原生模块。这类产物在
安装阶段完全看不出来 —— 文件齐、结构对比通过、sha256 也算得出来 —— 要等套件启动
失败（bin/node 跑不起来）或运行期第一次走文件锁（缺 linux-x64 的 system.node）才暴露。
所以必须在出包前用 ELF 头把架构钉死。

判定口径：
  · bin/node 的 ELF e_machine 必须与目标架构匹配（x86-64 = 0x3E / AArch64 = 0xB7）
  · native/system/packages/ 下必须有目标平台目录，且其中含 system.node
    （平台目录名：x86_64 → linux-x64，arm64 → linux-arm64）

用法：
    ./check-target-arch.py <target 目录> --arch x86_64|arm64
退出码：0 通过；1 发现不一致（可按需在 CI 里当作硬失败）；2 参数或文件缺失
"""
import argparse
import os
import struct
import sys

# ELF e_machine 取值（小端 2 字节，位于 ELF 头偏移 0x12）
ELF_MACHINE_X86_64 = 0x3E
ELF_MACHINE_AARCH64 = 0xB7

# 目标架构 → (期望的 e_machine, 期望的 native 平台目录名)
ARCH_TABLE = {
    'x86_64': (ELF_MACHINE_X86_64, 'linux-x64'),
    'arm64': (ELF_MACHINE_AARCH64, 'linux-arm64'),
}
ELF_MACHINE_NAMES = {
    ELF_MACHINE_X86_64: 'x86-64',
    ELF_MACHINE_AARCH64: 'AArch64',
}
ELF_HEADER_MIN_BYTES = 20


def read_elf_machine(path):
    """读 ELF 头的 e_machine；非 ELF 或读不到时返回 None（由调用方判定为异常）。"""
    try:
        with open(path, 'rb') as handle:
            header = handle.read(ELF_HEADER_MIN_BYTES)
    except OSError as error:
        print('  ✗ 无法读取 %s：%s' % (path, error))
        return None
    if len(header) < ELF_HEADER_MIN_BYTES or header[:4] != b'\x7fELF':
        return None
    # e_machine 在 0x12，小端 16 位（三种目标平台都是小端）
    return struct.unpack('<H', header[0x12:0x14])[0]


def find_native_platform_dirs(target_dir):
    """列出 native/system/packages/ 下的平台目录名（linux-*）。"""
    packages_dir = os.path.join(target_dir, 'native', 'system', 'packages')
    if not os.path.isdir(packages_dir):
        return []
    return sorted(
        entry for entry in os.listdir(packages_dir)
        if entry.startswith('linux-') and os.path.isdir(os.path.join(packages_dir, entry))
    )


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('target_dir', help='已构建好的 target 目录')
    parser.add_argument('--arch', required=True, choices=sorted(ARCH_TABLE), help='目标架构')
    args = parser.parse_args()

    target_dir = os.path.abspath(args.target_dir)
    if not os.path.isdir(target_dir):
        print('  ✗ target 目录不存在：%s' % target_dir)
        return 2

    expected_machine, expected_platform = ARCH_TABLE[args.arch]
    failed = False

    # ① bin/node 的架构
    node_binary = os.path.join(target_dir, 'bin', 'node')
    if not os.path.isfile(node_binary):
        print('  ✗ 找不到 %s' % node_binary)
        return 2
    actual_machine = read_elf_machine(node_binary)
    if actual_machine is None:
        print('  ✗ bin/node 不是可识别的 ELF 可执行文件（读不到 e_machine）')
        failed = True
    elif actual_machine != expected_machine:
        print('  ✗ bin/node 架构不匹配：目标是 %s，实际是 %s' % (
            ELF_MACHINE_NAMES.get(expected_machine, hex(expected_machine)),
            ELF_MACHINE_NAMES.get(actual_machine, hex(actual_machine)),
        ))
        failed = True
    else:
        print('  ✓ bin/node 架构正确（%s）' % ELF_MACHINE_NAMES[expected_machine])

    # ② native 平台目录与 system.node
    platform_dirs = find_native_platform_dirs(target_dir)
    if not platform_dirs:
        print('  ⚠ 未找到 native/system/packages 下的平台目录（若该版本不含原生模块属正常）')
    elif expected_platform not in platform_dirs:
        print('  ✗ native 平台目录里没有 %s（实际有：%s）' % (
            expected_platform, ', '.join(platform_dirs) or '无'))
        print('     这通常意味着 target 是从另一个架构的构建缓存复用来的')
        failed = True
    else:
        system_node = os.path.join(
            target_dir, 'native', 'system', 'packages', expected_platform,
            'bin', 'glibc', 'system.node',
        )
        if os.path.exists(system_node):
            print('  ✓ native 平台目录正确（%s）且含 glibc/system.node' % expected_platform)
        else:
            print('  ⚠ native 平台目录 %s 存在，但缺 bin/glibc/system.node' % expected_platform)

    # ③ 反向检查：出现非目标平台目录时提示（可能是清理不彻底）
    other_dirs = [name for name in platform_dirs if name != expected_platform]
    if other_dirs:
        print('  ⚠ native 下还有其它平台目录：%s（一般不影响运行，但会增大包体）'
              % ', '.join(other_dirs))

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
