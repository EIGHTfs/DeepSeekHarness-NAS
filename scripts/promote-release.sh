#!/bin/bash
# ============================================================
#  发布产物提升：暂存区 → release/
#
#  规则：release/ 只存放【实装验证通过】的包。
#        打包脚本产物一律先落到暂存区（build/staging/），
#        实装测试通过后再用本脚本拷进 release/。
#
#  用法：
#    scripts/promote-release.sh <包文件名> [更多包...]
#    scripts/promote-release.sh --list              # 看暂存区有什么
#    scripts/promote-release.sh --all               # 提升暂存区全部包
#    scripts/promote-release.sh --check <文件名>     # 只校验不拷贝
#
#  路径可用环境变量覆盖（与 build-common.sh / build-spk.sh / build-fpk.sh 一致）：
#    D_STAGING=... D_REL=...
# ============================================================
set -uo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"

# ── 目录解析：环境变量 > build-config.yaml > 默认 ──
D_BUILD="${D_BUILD:-$WS/build}"
D_STAGING="${D_STAGING:-$D_BUILD/staging}"
D_REL="${D_REL:-$WS/release}"
_CFG="$WS/build-config.yaml"

if [ -f "$_CFG" ]; then
  eval "$(python3 - "$_CFG" <<'PY' 2>/dev/null || true
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
d = cfg.get('defaults') or {}
for k in ('build_dir', 'release_dir', 'staging_dir'):
    if d.get(k):
        print(f'CFG_{k.upper()}="{d[k]}"')
PY
)"
  _resolve(){ case "$1" in /*) echo "$1";; *) echo "$WS/$1";; esac; }
  [ -n "${CFG_BUILD_DIR:-}" ]   && D_BUILD="$(_resolve "$CFG_BUILD_DIR")"
  [ -n "${CFG_STAGING_DIR:-}" ] && D_STAGING="$(_resolve "$CFG_STAGING_DIR")"
  [ -n "${CFG_RELEASE_DIR:-}" ] && D_REL="$(_resolve "$CFG_RELEASE_DIR")"
fi

die(){ echo "✗ $*" >&2; exit 1; }

[ -d "$D_STAGING" ] || die "暂存目录不存在: $D_STAGING（先跑 build-common.sh + build-spk.sh/build-fpk.sh）"
mkdir -p "$D_REL"

list_staging(){
  local f
  echo "暂存区: $D_STAGING"
  found=0
  for f in "$D_STAGING"/*.spk "$D_STAGING"/*.fpk; do
    [ -f "$f" ] || continue
    found=1
    printf '  %-58s %8s  MD5 %s\n' "$(basename "$f")" \
      "$(du -h "$f" | cut -f1)" "$(md5sum "$f" | awk '{print $1}')"
  done
  [ "$found" = "1" ] || echo "  （无包）"
  echo ""
  echo "发布目录: $D_REL"
  found=0
  for f in "$D_REL"/*.spk "$D_REL"/*.fpk; do
    [ -f "$f" ] || continue
    found=1
    printf '  %-58s %8s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  [ "$found" = "1" ] || echo "  （无包）"
}

# 包结构自检：spk=未压缩 tar、fpk=gzip；两者都必须含各自的特征条目
verify_pkg(){
  local f="$1" base kind
  base="$(basename "$f")"
  case "$base" in
    *.spk)
      kind="spk"
      tar -tf "$f" >/dev/null 2>&1 || { echo "  ✗ $base 不是合法 tar（spk 外层应为未压缩 tar）"; return 1; }
      tar -tf "$f" 2>/dev/null | grep -qx 'package.tgz' || { echo "  ✗ $base 缺 package.tgz"; return 1; }
      tar -tf "$f" 2>/dev/null | grep -qx 'INFO' || { echo "  ✗ $base 缺 INFO"; return 1; }
      ;;
    *.fpk)
      kind="fpk"
      tar -tzf "$f" >/dev/null 2>&1 || { echo "  ✗ $base 不是合法 gzip tar（fpk 外层应为 gzip）"; return 1; }
      tar -tzf "$f" 2>/dev/null | grep -qx 'app.tgz' || { echo "  ✗ $base 缺 app.tgz"; return 1; }
      tar -tzf "$f" 2>/dev/null | grep -qx 'manifest' || { echo "  ✗ $base 缺 manifest"; return 1; }
      ;;
    *) echo "  ✗ $base 扩展名须为 .spk 或 .fpk"; return 1 ;;
  esac
  echo "  ✓ $base 结构校验通过（$kind）"
  return 0
}

# 覆盖前拒绝：release/ 已存在同名且内容不同 → 要求显式确认
promote_one(){
  local name="$1" src="$D_STAGING/$1" dst="$D_REL/$1" check_only="${2:-0}"
  [ -f "$src" ] || die "暂存区无此包: $src"
  verify_pkg "$src" || die "结构校验未通过，拒绝提升: $name"
  if [ "$check_only" = "1" ]; then
    echo "  （--check 模式，未拷贝）"
    return 0
  fi
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    echo "  ⚠ $dst 已存在且内容不同 —— 覆盖前请确认这是预期的新版本"
    [ "${FORCE:-0}" = "1" ] || die "已存在同名不同内容，加 FORCE=1 才覆盖"
  fi
  cp -f "$src" "$dst" || die "拷贝失败: $src → $dst"
  echo "  ✓ 已提升 → $dst ($(du -h "$dst" | cut -f1) | MD5 $(md5sum "$dst" | awk '{print $1}'))"
}

# ── 参数解析 ──
[ $# -ge 1 ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  --list|-l) list_staging; exit 0 ;;
  --check|-c) shift
    [ $# -ge 1 ] || die "--check 需要包文件名"
    echo "▶ 仅校验（不拷贝）"
    for n in "$@"; do promote_one "$n" 1; done
    exit 0 ;;
  --all|-a)
    echo "▶ 提升暂存区全部包 → $D_REL"
    found=0
    for f in "$D_STAGING"/*.spk "$D_STAGING"/*.fpk; do
      [ -f "$f" ] || continue
      found=1
      promote_one "$(basename "$f")"
    done
    [ "$found" = "1" ] || die "暂存区没有可提升的包"
    exit 0 ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

echo "▶ 提升 → $D_REL"
for n in "$@"; do promote_one "$n"; done
echo "完成。release/ 现有："
ls -1 "$D_REL"/*.spk "$D_REL"/*.fpk 2>/dev/null | sed 's|.*/|  |' || echo "  （空）"
