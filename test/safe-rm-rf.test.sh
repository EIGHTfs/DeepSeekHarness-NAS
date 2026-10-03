#!/usr/bin/env bash
#===============================================================================
# test/safe-rm-rf.test.sh — 事故回归测试：**含挂载点的目录绝不能被删**
#
# 背景（2026-10-03 事故）：rm -rf /volume1/@appdata/<PKG> 递归进入其下的 NFS 挂载点，
#   在**源端**删光用户工作区，不可恢复。修复为 scripts/lib/common.sh 的
#   has_mount_under() + safe_rm_rf()（强制 --one-file-system + 显式挂载点检测）。
#
# 本测试**不需要 root、不触碰任何真实挂载**：
#   · 用 /proc（任何 Linux 上必然存在的挂载点）断言"检出挂载"能力；
#   · 用临时目录断言"无挂载 → 正常删除"；
#   · 断言 safe_rm_rf 对含挂载目录**跳过且返回非 0**，且该目录**仍然存在**。
#===============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
. "$ROOT/scripts/lib/common.sh"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1（期望 $3，实际 $2）"; fail=1; fi; }

echo "▶ safe_rm_rf 回归测试"

# 1) 检出挂载点（/proc 必然存在）
has_mount_under /proc; chk "has_mount_under /proc 检出挂载" "$?" "0"

# 2) 无挂载的临时目录 → 正常删除
T="$(mktemp -d)"; mkdir -p "$T/plain"; touch "$T/plain/f"
safe_rm_rf "$T/plain" >/dev/null 2>&1; rc=$?
chk "safe_rm_rf 普通目录返回 0" "$rc" "0"
[ -e "$T/plain" ] && chk "普通目录已被删除" "存在" "已删" || chk "普通目录已被删除" "已删" "已删"

# 3) 含挂载点的目录 → 跳过、返回非 0、目录仍在
safe_rm_rf /proc >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] && chk "safe_rm_rf /proc 返回非 0（已跳过）" "非0" "非0" || chk "safe_rm_rf /proc 返回非 0（已跳过）" "0" "非0"
[ -d /proc ] && chk "含挂载点的 /proc 未被删除" "保留" "保留" || chk "含挂载点的 /proc 未被删除" "被删" "保留"

# 4) 关键语义：检测的是「**dir 之下**是否有挂载」——事故场景正属此列
#    （@appdata/<PKG>/<版本>/工作区 就是其下的 NFS 挂载点）
has_mount_under /; chk "has_mount_under / 检出其下的挂载（事故同型）" "$?" "0"
T2="$(mktemp -d)"; mkdir -p "$T2/@appdata/PKG/ver"
has_mount_under "$T2"; chk "普通临时目录无挂载（不误报）" "$?" "1"
rm -rf "$T" "$T2" 2>/dev/null

if [ "$fail" = "0" ]; then echo "✓ 全部通过"; exit 0; else echo "✗ 存在失败"; exit 1; fi
