#!/bin/bash
#===============================================================================
# DeepSeek Harness NAS — 一键构建（本地等效于 GitHub Actions）
#===============================================================================
# 【本脚本定位】
#   把 .github/workflows/build.yml 的 CI 流程在本地复现成一条命令：
#     拉最新官方源 → 公共预编译 → 打包 → 产物落 build/staging/
#   CI 与本脚本跑的是【同一批脚本】，不存在两套构建逻辑（改一处两边同步）。
#
# 【与其他脚本的关系】
#   fetch-dsh-latest.sh  拉官方最新源码 → src/deepseek-ai/<tag>（本脚本调用）
#   build-common.sh      源码 monorepo 编译 + 裁剪 → target（spk / fpk 源码链路）
#   build-npm-app.sh     npm 装官方包 → app_root（fpk npm 链路，快，无需编译）
#   build-spk.sh         消费 target → 群晖 .spk
#   build-fpk.sh         消费 target 或 app_root → 飞牛 .fpk（--npm 走 npm 链路）
#   build-all.sh         【本脚本】编排以上四步，按 --targets 选择产物
#
# 【用法】
#   ./build/build-all.sh                     # 默认：拉源 + 出 spk + fpk（npm 链路）
#   ./build/build-all.sh --targets spk       # 只出 spk（源码链路，约 15-20 分钟）
#   ./build/build-all.sh --targets fpk       # 只出 fpk（npm 链路，约 12 分钟）
#   ./build/build-all.sh --targets spk,fpk   # 两个都出
#   ./build/build-all.sh --fpk-mode src      # fpk 改走源码链路（体积大、无需 npm）
#   ./build/build-all.sh --tag dsh-v0.1.5-rc.2   # 指定官方 tag，不自动判最新
#   ./build/build-all.sh --skip-fetch        # 跳过拉源，复用已有 src/
#   ./build/build-all.sh --dry-run           # 只打印将执行的命令，不动手
#
# 【参数】
#   --targets LIST  逗号分隔：spk / fpk（缺省 spk,fpk）
#   --fpk-mode MODE fpk 产物来源：npm（缺省，快）| src（源码编译）
#   --tag TAG       指定官方源码 tag（透传给 fetch-dsh-latest.sh）
#   --skip-fetch    跳过拉取官方源码（复用 src/ 现有内容）
#   --dry-run       只打印命令不执行
#   -h, --help      显示本帮助
#
# 【产物】
#   build/staging/<APP_NAME>_<平台>-<版本>.spk
#   build/staging/<APP_NAME>_<平台>-<版本>.fpk
#   实测通过后用 scripts/promote-release.sh <包文件名> 提升到 release/
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 默认参数 ──
TARGETS="spk,fpk"
FPK_MODE="npm"
TAG=""
SKIP_FETCH=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --targets)     TARGETS="${2:?--targets 需要一个值}"; shift 2 ;;
    --targets=*)   TARGETS="${1#*=}"; shift ;;
    --fpk-mode)    FPK_MODE="${2:?--fpk-mode 需要一个值}"; shift 2 ;;
    --fpk-mode=*)  FPK_MODE="${1#*=}"; shift ;;
    --tag)         TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --tag=*)       TAG="${1#*=}"; shift ;;
    --skip-fetch)  SKIP_FETCH=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "[!] 未知参数: $1（用 --help 看用法）" >&2; exit 1 ;;
  esac
done

# ── 参数校验（早失败，不浪费时间） ──
case "$FPK_MODE" in npm|src) ;; *) echo "[!] --fpk-mode 只能是 npm 或 src，收到: $FPK_MODE" >&2; exit 1 ;; esac
_IFS_OLD="$IFS"; IFS=','; set -- $TARGETS; IFS="$_IFS_OLD"
for t in "$@"; do
  case "$t" in spk|fpk) ;; *) echo "[!] --targets 只支持 spk / fpk，收到: $t" >&2; exit 1 ;; esac
done
want_spk=0; want_fpk=0
for t in "$@"; do
  [ "$t" = "spk" ] && want_spk=1
  [ "$t" = "fpk" ] && want_fpk=1
done

run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $*"
  else
    echo "  ▶ $*"
    "$@"
  fi
}

echo "════════════════════════════════════════════════"
echo "  DeepSeek Harness NAS — 一键构建"
echo "  产物    : ${TARGETS}"
echo "  fpk 链路: ${FPK_MODE}"
echo "  源码 tag: ${TAG:-自动取最新}"
echo "  跳过拉源: $([ "$SKIP_FETCH" = 1 ] && echo 是 || echo 否)"
echo "  dry-run : $([ "$DRY_RUN" = 1 ] && echo 是 || echo 否)"
echo "════════════════════════════════════════════════"

# ── ① 拉取官方最新源码（spk 必做；fpk npm 链路可跳过） ──
#  注：npm 链路不需要源码（直接 npm 装官方包），所以只出 fpk --fpk-mode npm 时跳过拉源，
#      省掉一次完整 clone；但 spk 或 fpk src 链路必须要有源码。
if [ "$want_spk" = "1" ] || { [ "$want_fpk" = "1" ] && [ "$FPK_MODE" = "src" ]; }; then
  if [ "$SKIP_FETCH" = "1" ]; then
    echo "① 拉取官方源码 —— 跳过（--skip-fetch）"
  else
    echo "① 拉取官方最新源码"
    if [ -n "$TAG" ]; then
      run "$WS/fetch-dsh-latest.sh" --tag "$TAG"
    else
      run "$WS/fetch-dsh-latest.sh"
    fi
  fi
else
  echo "① 拉取官方源码 —— 不需要（纯 fpk npm 链路）"
fi

# ── ② 公共预编译（源码链路前置；npm 链路不需要编译） ──
if [ "$want_spk" = "1" ] || { [ "$want_fpk" = "1" ] && [ "$FPK_MODE" = "src" ]; }; then
  echo "② 公共预编译（pnpm install + build + 裁剪 → target）"
  run "$SCRIPT_DIR/build-common.sh"
else
  echo "② 公共预编译 —— 不需要（纯 fpk npm 链路）"
fi

# ── ③ 打包 ──
if [ "$want_spk" = "1" ]; then
  echo "③ 打 SPK（消费 target）"
  run "$SCRIPT_DIR/build-spk.sh"
fi

if [ "$want_fpk" = "1" ]; then
  if [ "$FPK_MODE" = "npm" ]; then
    echo "③ 构建 npm 应用体（npm 装官方包 → app_root）"
    run "$SCRIPT_DIR/build-npm-app.sh"
    echo "③ 打 FPK（--npm 消费 app_root）"
    run "$SCRIPT_DIR/build-fpk.sh" --npm
  else
    echo "③ 打 FPK（源码链路，消费 target）"
    run "$SCRIPT_DIR/build-fpk.sh"
  fi
fi

# ── ④ 产物汇总 ──
echo ""
echo "════════════════════════════════════════════════"
echo "✅ 构建完成"
if [ "$DRY_RUN" = "1" ]; then
  echo "  （dry-run：未真正执行，无产物）"
else
  shopt -s nullglob
  found=0
  for f in "$WS"/build/staging/*.spk "$WS"/build/staging/*.fpk; do
    printf "  %-58s %8.1f MiB\n" "$(basename "$f")" "$(echo "scale=1; $(stat -c %s "$f")/1048576" | bc)"
    found=1
  done
  [ "$found" = "0" ] && echo "  （build/staging 下没有 .spk/.fpk 产物）"
fi
echo "────────────────────────────────────────────────"
echo "  暂存区只放未验证产物；实机安装验证通过后执行："
echo "    scripts/promote-release.sh <包文件名>"
echo "════════════════════════════════════════════════"
