#!/bin/bash
# 公共内核 · 环境与工具层（平台无关；任何平台适配器都不得改写本文件）
#
# 职责：node/pnpm 自探测与自举、目录树复制、日志与 dry-run 小工具。
#   本文件只放「与某个打包格式无关」的东西；平台专有逻辑一律进 build/platform/<平台>.sh。
#   由 build-common.sh 在解析完 BUILD_ROOT / WS / BUILD_STAGE / DRY_RUN 之后 source。

_STAGE_OK() { [ "$BUILD_STAGE" = "all" ] || [ "$BUILD_STAGE" = "$1" ]; }

# ── 编译 dry-run：所有阶段均可预演，不执行任何编译/裁剪/写盘 ──
#   ./build-common.sh [SRC] [SKIP_BUILD] --dry-run     # 或 DRY_RUN=1
#   仅报告：阶段计划、源码/版本/node/编译器自探测结果、白名单与排除规则统计。
#   另外报告：现有 target 体积、各阶段将执行的具体动作（逐条 [dry-run] 列出）。
_dry() { [ "$DRY_RUN" = "1" ]; }
# 预演提示（dry-run 时打印一行；非 dry-run 静默）
dry_note() { if _dry; then echo "  [dry-run] $1"; fi; return 0; }
# GitHub annotation：存在 check run 里，日志 blob 丢（BlobNotFound）也能从 API 拿
_ANN() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$1" || echo "[stage] $1"; }

# ── 日志：段耗时 + CI 折叠分组（便于看出哪一段慢）────────
#   动机：在线构建偶发变慢，但日志里只有阶段名、没有耗时 → 无法回答"慢在哪"。
#   用法：在每个阶段边界调 _tick "阶段名"（打印【本段】与【累计】耗时并累计到汇总）。
#   · CI 里用 ::group:: / ::endgroup:: 折叠，本地退化为 ▶ 一行。
#   · 全部只在 stdout 打，不改任何行为、不写文件。
_DSH_T_START="${_DSH_T_START:-$(date +%s)}"
_DSH_T_LAST="$_DSH_T_START"
_DSH_PHASES=""
_tick() {
  local _now _seg _tot
  _now="$(date +%s)"
  _seg=$(( _now - _DSH_T_LAST )); _tot=$(( _now - _DSH_T_START ))
  _DSH_T_LAST="$_now"
  # 用 | 分隔：阶段名里含空格与括号，绝不能靠空格切分（实测会打印成乱码）
  _DSH_PHASES="${_DSH_PHASES}${1}|$(printf '%dm%02ds' $((_seg/60)) $((_seg%60)))
"
  printf '⏱  %-32s 本段 %dm%02ds   累计 %dm%02ds\n' "$1" $((_seg/60)) $((_seg%60)) $((_tot/60)) $((_tot%60))
  return 0
}
_group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$1"; else echo "▶ $1"; fi; return 0; }
_endgroup() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"; return 0; }

node_has_headers() {  # $1=node 可执行文件路径 → 校验同级/上级 include/node/node_api.h
  local _n="$1" _d
  [ -x "$_n" ] || return 1
  _d="$(dirname "$_n")"
  [ -f "$_d/../include/node/node_api.h" ] || [ -f "$_d/include/node/node_api.h" ]
}
resolve_node_src() {
  local _c=""
  # ① 首选 /usr/bin/node —— 但**必须可执行**才算数。
  #    旧写法最后直接 echo /usr/bin/node，不校验存在性：本机（193）该路径不存在。
  #    于是垫片被写死成 exec "/usr/bin/node" → 每次 pnpm install 都报
  #    "/usr/bin/node: No such file or directory"。
  #    判据：优先 /usr/bin/node，不可执行则自探测。
  if [ -x /usr/bin/node ]; then echo "/usr/bin/node"; return 0; fi
  # ② 自探测（先要带 headers 的：native 编译需要）
  _c="$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | sort -V | tail -1)"
  if node_has_headers "$_c"; then echo "$_c"; return 0; fi
  _c="$(command -v node 2>/dev/null || true)"
  if node_has_headers "$_c"; then echo "$_c"; return 0; fi
  # ③ 退一步：任何**可执行**的 node（不带 headers 也比写死不存在强）
  for _c in /usr/local/bin/node \
            "$(ls -d "$WS"/tools/node-dist/node-v*/bin/node 2>/dev/null | sort -V | tail -1)" \
            "$(command -v node 2>/dev/null || true)" \
            "${SYNOPKG_PKGDEST:-}/bin/node"; do
    [ -n "$_c" ] && [ -x "$_c" ] && { echo "$_c"; return 0; }
  done
  echo "/usr/bin/node"
}

ensure_pnpm_engine() {
  if [ -f "$PNPM_BIN" ] && [ -f "$WS/tools/pnpm/dist/pnpm.mjs" ]; then
    return 0  # bin + dist 齐全，直接可用
  fi
  echo "▶ pnpm 引擎缺失（tools/pnpm/dist 不入库），自动安装 pnpm…"
  mkdir -p "$WS/tools/pnpm"
  local _ver _tmp
  _ver="$(cat "$WS/tools/pnpm/package.json" 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('version','11.25.0'))" 2>/dev/null \
    || echo '11.25.0')"
  _tmp="$(mktemp -d)"
  if command -v npm >/dev/null 2>&1; then
    ( cd "$_tmp" && npm pack "pnpm@$_ver" --silent 2>/dev/null ) \
      && tar -xzf "$_tmp"/pnpm-*.tgz -C "$WS/tools/pnpm" --strip-components=1 2>/dev/null
  fi
  safe_rm_rf "$_tmp"
  if [ -f "$WS/tools/pnpm/dist/pnpm.mjs" ]; then
    echo "  ✓ pnpm 引擎就绪 (tools/pnpm/dist/pnpm.mjs, v$_ver)"
  else
    echo "  ✗ pnpm 引擎安装失败：npm 不可用或下载失败，请 npm install -g pnpm@$_ver 后重试" >&2
    return 1
  fi
}

copy_tree_tar() {
  local src_dir="$1" dst_dir="$2" _tar_err _real_err _src_n _dst_n
  _tar_err="$(mktemp)"
  ( cd "$src_dir" && tar -cf - --hard-dereference . ) 2>/dev/null \
    | ( cd "$dst_dir" && tar -xf - --no-same-owner --no-same-permissions --touch ) 2>"$_tar_err"
  _real_err="$(grep -vE 'Cannot (utime|change mode|chmod|chown)|Exiting with failure status' "$_tar_err" 2>/dev/null || true)"
  if [ -n "$_real_err" ]; then
    err "复制源码出现非权限类错误："
    printf '%s\n' "$_real_err" | head -5 >&2
    rm -f "$_tar_err"
    return 1
  fi
  rm -f "$_tar_err"
  _src_n="$(find "$src_dir" -type f 2>/dev/null | wc -l)"
  _dst_n="$(find "$dst_dir" -type f 2>/dev/null | wc -l)"
  if [ "$_src_n" != "$_dst_n" ]; then
    err "复制不完整：源 $_src_n 个文件，目标 $_dst_n 个"
    return 1
  fi
  return 0
}
