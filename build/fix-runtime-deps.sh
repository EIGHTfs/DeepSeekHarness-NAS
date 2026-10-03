#!/bin/bash
#===============================================================================
# fix-runtime-deps.sh — 运行时精准补包
#   （2026-10-02 建；2026-10-03 入口集自学习 + 失败不再静默）
#===============================================================================
# 【背景】裁剪白名单（lockfileDeps，来自 npm 链路 lock）与源码构建的 .pnpm
#   （pnpm 链路）有差异：npm 白名单会把 pnpm 装的运行时传递依赖漏掉
#   （实测 execa 的 is-plain-obj/get-stream/… 被裁）→ 装完 DSH 启动时报
#   "Cannot find package 'x'"（plugin-manager 等内置插件 failed to import）。
#   全量闭包解法（从整个白名单 BFS）会保留几百个开发/测试/构建工具 → 体积膨胀
#   （136MB → 362MB），不值得。
#
# 【本方案】**探测驱动精准补包**：裁剪后逐一 import 运行时入口 → 报缺的包
#   从构建副本 BUILD_SRC 的 .pnpm 恢复（pnpm 依赖软链是相对路径，恢复 .pnpm
#   目录即自动生效）→ 迭代到所有入口 import 干净。
#
# 【2026-10-03 修正 1：入口集改为从 bundle 自学习（关键）】
#   旧实现把入口写死成 `packages/boot/*/lib/index.js + apps/cli/lib/bin.js`，
#   但**插件是在各自 bundle 的解析上下文里被加载的**：bundle 的 cordis.patch.yml
#   按名引用 `@deepseek-ai/dsh-*`，由 bundle 自己 node_modules 里的 pnpm 软链解析。
#   写死的入口探不到这些包，实测漏掉两处（10.10.10.64 / 10.10.10.193 两台机器
#   装出来的包都带这两个缺包，DSH 启动长期有 failed to import 警告）：
#       got@14.6.6                    → @sindresorhus/is   （dsh-otel 挂）
#       @deepseek-ai/libreoffice-kit  → fontkit            （dsh-office-to-pdf 挂）
#   现改为**从每个 bundle 的 package.json 学入口**：取它声明的 `@deepseek-ai/dsh-*`
#   依赖，切到该 bundle 目录按名 import（复刻运行时解析上下文与 ESM 条件），
#   因此能探到 bundle 侧插件的传递依赖缺失。
#   实测（2026-10-03，0.2.0-rc.2 裁剪树）：
#       bundle/base    92 个声明插件 → 命中 1 个真缺（@sindresorhus/is）
#       bundle/web-app 124 个声明插件 → 命中 1 个真缺（fontkit）
#       0 假阳性
#   ⚠ 不要改成「读 package.json 的 main 再拼路径 import」：只声明 exports 的包
#     （如 @deepseek-ai/dsh-web-frontend）会因此误报缺包的假阳性。按名 import、
#     交给 node 自己解析，才是正确口径。
#
# 【2026-10-03 修正 2：不再静默失败】
#   旧实现在 BUILD_SRC 里找不到对应 .pnpm 目录时 `|| true` 跳过，循环跑满后
#   照样打印 "✓ 精准补包完成" 并 exit 0 —— CI 会静默产出缺包的包
#   （与文件头 2026-10-02 记录的 "CI 补包静默失败" 属同一类坑）。
#   现在：记录恢复不了的包，最后一轮探测仍不干净就 exit 1 并列出缺包。
#
# 【2026-10-03 修正 3：两个自噬 bug】
#   a) 参数解析原为 `*) NODE_BIN="$1" ;;` 且分支内不 shift → 传任何多余参数会
#      死循环（无参数时跑不到，故长期未暴露）。改为每个分支各自 shift。
#   b) 原 NODE_BIN 兜底写 `"${1:+$TARGET/bin/node}"`，但此处 $1 已在 shift 2 后
#      被吃掉 → 该兜底永不生效（④ 形同虚设）。改为显式判断 TARGET/bin/node。
#
# 【用法】./build/fix-runtime-deps.sh <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]
#   TARGET      已裁剪的 target（缺包被删）
#   BUILD_SRC   完整构建副本（含全量 node_modules，补包来源）
#               ⚠ 必须真的是"完整"：若它自身也被白名单裁剪过（prune-target.sh
#                 模式 C 裁的就是 BUILD_SRC），缺包同样恢复不了 → 本脚本 exit 1。
#                 此时先把缺包并入 build/build-prune-whitelist.json 的 lockfileDeps：
#                 scripts/learn-prune-whitelist.sh --runtime <TARGET> --apply
#   NODE_BIN    node 可执行文件（缺省自探测 tools/node-dist → PATH → TARGET/bin/node）
#   --max-rounds N  最大迭代轮数（默认 25）
#===============================================================================
set -euo pipefail

TARGET="${1:?用法: $0 <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]}"
BUILD_SRC="${2:?用法: $0 <TARGET> <BUILD_SRC> [NODE_BIN] [--max-rounds N]}"
MAX_ROUNDS=25
NODE_BIN=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --max-rounds) MAX_ROUNDS="${2:?--max-rounds 需要一个数字}"; shift 2 ;;
    *) NODE_BIN="$1"; shift ;;
  esac
done

# 路径绝对化：detect() 内部会 cd 到 TARGET，相对路径会算错
TARGET="$(cd "$TARGET" && pwd)" || { echo "✗ TARGET 不存在: $TARGET" >&2; exit 1; }
BUILD_SRC="$(cd "$BUILD_SRC" && pwd)" || { echo "✗ BUILD_SRC 不存在: $BUILD_SRC" >&2; exit 1; }
[ -d "$BUILD_SRC/node_modules/.pnpm" ] || { echo "✗ BUILD_SRC 无 node_modules/.pnpm: $BUILD_SRC" >&2; exit 1; }
[ -d "$TARGET/node_modules/.pnpm" ] || { echo "✗ TARGET 无 node_modules/.pnpm: $TARGET" >&2; exit 1; }

# NODE_BIN 自探测（2026-10-02 修正：CI 无 tools/node-dist，需回退 PATH 的 node）：
#   ① 显式传参 → ② 项目 tools/node-dist（本地构建缓存）→ ③ command -v node
#   （CI 的 setup-node）→ ④ TARGET/bin/node（已随包）
# ⚠ 命令替换内管道在 set -euo pipefail 下的坑（2026-10-02 实测第 5 层根因）：
#   NODE_BIN="$(ls ... | head -1)" —— CI 无 tools/node-dist 时 ls 失败 → 管道非零
#   → 命令替换非零 → set -e 立即退出（连 command -v 回退都没机会跑）。每个命令
#   替换必须内联 || true，不能只靠下一行的兜底。
if [ -z "$NODE_BIN" ]; then
  NODE_BIN="$(ls -d "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"/tools/node-dist/node-v*/bin/node 2>/dev/null | head -1 || true)"
fi
if [ -z "$NODE_BIN" ]; then NODE_BIN="$(command -v node 2>/dev/null || true)"; fi
if [ -z "$NODE_BIN" ] && [ -x "$TARGET/bin/node" ]; then NODE_BIN="$TARGET/bin/node"; fi
[ -x "$NODE_BIN" ] || { echo "✗ 未找到 node: ${NODE_BIN:-（空）}（请显式传 NODE_BIN）" >&2; exit 1; }

# 探测脚本（存成 shell 变量，用 node -e 执行）
# ⚠ 必须用 `-e` 而不是「把 JS 写成临时 .mjs 再执行」：ESM 下裸包名的解析基准是
#   **执行文件所在目录**，不是 cwd。把探测脚本放 /tmp 会让所有插件都解析失败
#   （2026-10-03 实测：190 个 @deepseek-ai/dsh-* 全被误报成缺包）。
#   `--input-type=module -e` 的基准是 cwd，配合 `cd <bundle>` 才复刻运行时上下文。
PROBE_JS=$(cat <<'PROBE_EOF'
const names = (process.env.DSH_PROBE_NAMES || '').split(',').filter(Boolean);
for (const n of names) {
  try { await import(n); }
  catch (e) { if (e && e.message) console.log('MISS:' + e.message); }
}
PROBE_EOF
)

# 取某个 bundle 声明的宿主侧插件名（@deepseek-ai/dsh-*）
DEPS_JS=$(cat <<'DEPS_EOF'
const fs = require('fs');
try {
  const p = JSON.parse(fs.readFileSync(process.env.DSH_PKG_JSON, 'utf-8'));
  process.stdout.write(Object.keys(p.dependencies || {})
    .filter(d => d.startsWith('@deepseek-ai/dsh-')).join(','));
} catch {}
DEPS_EOF
)

# 从 node 报错行里抽出缺失包名
# 兼容两种措辞：Cannot find package 'x'（裸包名解析失败）
#               Cannot find module 'x'（悬空软链/路径解析失败，2026-10-03 补）
# 只剔除路径形态（./  ../  /abs  node:xxx）；**scoped 包（@scope/name）必须保留**
extract_miss() {
  {
    grep -oE "Cannot find (package|module) '[^']+'" 2>/dev/null \
      | sed -E "s/Cannot find (package|module) '//;s/'//"
  } | grep -vE '^(\.|/|node:)' || true
}

# 把一次探测的原始输出转成 "<包名>\t<来源标签>" 行
# 来源标签很重要：同一个缺包卡住的是哪个入口/bundle，操作者据此判断影响面
emit_miss() {
  local label="$1" out="$2" p
  for p in $(printf '%s' "$out" | extract_miss); do
    printf '%s\t%s\n' "$p" "$label"
  done
}

# 探测：两层入口 → 输出 "<包名>\t<来源>"（每行一个）
# ⚠ set -euo pipefail 下，管道内 grep 无匹配会返回非零导致提前退出，故每处都要 || true
detect() {
  cd "$TARGET" || return 0
  local out entry b bdir names
  # ① 固定根（兜底）：CLI 入口 + boot 系内置插件
  for entry in packages/boot/*/lib/index.js apps/cli/lib/bin.js; do
    if [ ! -f "$entry" ]; then continue; fi
    out=$(timeout 30 "$NODE_BIN" --input-type=module -e "
      try { await import('file://$PWD/$entry'); }
      catch(e) { if (e && e.message) console.log('MISS:' + e.message); }" 2>&1) || true
    emit_miss "$entry" "$out"
  done
  # ② 自学习：从每个 bundle 声明的插件学入口，在该 bundle 目录里按名 import
  #    （cwd=该 bundle 目录 ⇒ ESM 裸包解析复刻运行时上下文）
  for b in packages/bundle/*/; do
    if [ ! -f "${b}package.json" ]; then continue; fi
    bdir="$TARGET/${b%/}"
    names=$(DSH_PKG_JSON="$bdir/package.json" "$NODE_BIN" -e "$DEPS_JS" 2>/dev/null || true)
    if [ -z "$names" ]; then continue; fi
    out=$(cd "$bdir" && DSH_PROBE_NAMES="$names" timeout 90 "$NODE_BIN" --input-type=module -e "$PROBE_JS" 2>&1) || true
    emit_miss "${b%/}" "$out"
  done
}

# 缺包名（去重）
names_of() { printf '%s' "$1" | cut -f1 | grep -v '^$' | sort -u || true; }
# 失败报告：按来源分组
detail_of() {
  printf '%s' "$1" | grep -v '^$' | awk -F'\t' '{a[$2]=a[$2]" "$1} END{for(k in a) printf "    %s →%s\n", k, a[k]}' || true
}

restored=0
unresolved=""
for round in $(seq 1 "$MAX_ROUNDS"); do
  det=$(detect || true)   # detect 内 grep 无匹配时管道非零，set -e 下需 || true
  missing=$(names_of "$det")
  if [ -z "$missing" ]; then
    echo "✓ 运行时依赖完整（第 $round 轮探测通过）"
    unresolved=""
    break
  fi
  echo "▶ 第 $round 轮缺包: $(printf '%s' "$missing" | tr '\n' ' ')"
  round_restored=0
  for pkg in $missing; do
    pdir="${pkg//\//+}"   # scoped 包：/ → +（pnpm 目录命名）
    found=0
    for d in "$BUILD_SRC"/node_modules/.pnpm/"${pdir}"@*; do
      if [ ! -d "$d" ]; then continue; fi
      cp -a "$d" "$TARGET/node_modules/.pnpm/" 2>/dev/null || true
      echo "  ✓ 恢复: $(basename "$d")"
      restored=$((restored + 1))
      round_restored=$((round_restored + 1))
      found=1
    done
    if [ "$found" = 0 ]; then
      echo "  ✗ BUILD_SRC 无此包，无法恢复: $pkg"
      unresolved="$unresolved$pkg"$'\n'
    fi
  done
  if [ "$round_restored" = 0 ]; then
    echo "  ⚠ 本轮无任何包可恢复，提前结束迭代（继续跑只是空转）"
    break
  fi
done

# 终判：仍缺即失败（绝不静默产出缺包的包）
final_det=$(detect || true)
final_missing=$(names_of "$final_det")
if [ -n "$final_missing" ]; then
  {
    echo "✗ 补包未完成：以下运行时依赖仍然缺失（含来源，便于判断影响面）"
    detail_of "$final_det"
    echo "  TARGET     : $TARGET"
    echo "  BUILD_SRC  : $BUILD_SRC"
    if [ -n "$unresolved" ]; then
      echo "  其中 BUILD_SRC 里根本没有的包（补包源自身就不完整）:"
      printf '%s' "$unresolved" | sort -u | grep -v '^$' | sed 's/^/    * /' || true
    fi
    echo "  建议：BUILD_SRC 必须是真正的完整构建副本。若它自身也被白名单裁剪过"
    echo "        （prune-target.sh 模式 C 裁的就是 BUILD_SRC），先补齐白名单再重跑："
    echo "          scripts/learn-prune-whitelist.sh --runtime \"$TARGET\" --apply"
    echo "  注意：来源里的 bundle/xxx 是声明该插件的 profile；web 部署只加载 base + web-app，"
    echo "        其余 bundle（acp-app / sdk-app / headless / sdk-minimal）的缺包不影响 web 运行。"
  } >&2
  exit 1
fi
echo "✓ 精准补包完成：恢复 $restored 个缺失包（target=$(du -sh "$TARGET" 2>/dev/null | cut -f1)）"
exit 0
