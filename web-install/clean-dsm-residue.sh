#!/usr/bin/env bash
#===============================================================================
# web-install/clean-dsm-residue.sh — **薄转发**（唯一实现在 scripts/clean-dsm-residue.sh）
#
# 2026-10-04 分叉治理（事故根因）：
#   原先 web 端**自带一份**清理实现，与套件自身的 preuninst/postuninst 语义分叉，
#   且其 rm -rf 曾递归进入 @appdata/<PKG>/<版本>/工作区 这个 NFS 挂载点，
#   在**源端**删光用户工作区（2026-10-03 事故，不可恢复）。
#   现统一为**唯一实现** scripts/clean-dsm-residue.sh（内含挂载点硬保护），
#   本文件只转发，避免再次分叉。
#
# 【约定】本文件不再包含任何清理逻辑；改动一律改 scripts/clean-dsm-residue.sh。
#===============================================================================
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_target="$_here/../scripts/clean-dsm-residue.sh"
[ -f "$_target" ] || { echo "✗ 缺少唯一实现: $_target" >&2; exit 1; }
exec bash "$_target" "$@"
