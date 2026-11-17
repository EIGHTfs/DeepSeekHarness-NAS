#!/usr/bin/env bash
# platform-paths.sh —— 平台路径与外部工具的「单一出处」。
#
# 为什么需要它（审计里 169 条 blocker 的根源）：
#   同一个平台路径（/var/packages、/volume1/@appdata、/tmp、corepack 的 pnpm.mjs）被散写在
#   十几个脚本里，既是噪音也是隐患 —— 平台改了规则要全仓 grep 改，漏一处就静默失效。
#   收敛到这里之后：脚本只引用变量/函数，平台知识只有一份；审计命中面从「十几个文件」缩到「这一个文件」。
#
# 设计原则（三条，改之前先读）：
#   1. **默认值即真实绝对路径**：变量一律写成 ${VAR:-默认绝对路径}，环境变量可覆盖。
#      —— 覆盖能力不是给生产用的，是给测试注入假根、给非标准部署兜底用的。
#   2. **不允许回落成空**：拿不到就显式报错，绝不拼出 "/target" 这种半截路径
#      （那会让删除/写入操作指向根目录附近，比失败危险得多）。
#   3. **只放「运行期要用的路径与工具」，不放「要写进安装包内容的路径」**：
#      pack-spk/pack-fpk 生成的目标机路径必须保持字面量，不归这里管。
#
# 用法：脚本里 source 它，然后只用下面的变量/函数
#   SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SELF_DIR/lib/platform-paths.sh"

# ── 群晖（DSM）────────────────────────────────────────────────────────────
# 优先用套件脚本自带的 SYNOPKG_* 变量（由 DSM 注入，官方口径）；
# 不在套件上下文里（如手工执行脚本）时回落到标准绝对路径。
PLATFORM_DSM_PKG_ROOT="${PLATFORM_DSM_PKG_ROOT:-/var/packages}"
PLATFORM_DSM_APPSTORE_ROOT="${PLATFORM_DSM_APPSTORE_ROOT:-/volume1/@appstore}"
PLATFORM_DSM_APPDATA_ROOT="${PLATFORM_DSM_APPDATA_ROOT:-/volume1/@appdata}"
PLATFORM_DSM_APPCONF_ROOT="${PLATFORM_DSM_APPCONF_ROOT:-/volume1/@appconf}"
PLATFORM_DSM_APPHOME_ROOT="${PLATFORM_DSM_APPHOME_ROOT:-/volume1/@apphome}"
PLATFORM_DSM_LOG_ROOT="${PLATFORM_DSM_LOG_ROOT:-/var/log/packages}"

# ── 飞牛（fnOS）───────────────────────────────────────────────────────────
PLATFORM_FNOS_APPS_ROOT="${PLATFORM_FNOS_APPS_ROOT:-/var/apps}"
PLATFORM_FNOS_APPCENTER_ROOT="${PLATFORM_FNOS_APPCENTER_ROOT:-/vol1/@appcenter}"

# ── 临时目录 ──────────────────────────────────────────────────────────────
# 默认 /tmp，**不跟随 TMPDIR**：实测本机 shell 里的 TMPDIR 指向套件自己的 tmp 目录
#   （/var/packages/<pkg>/tmp），照抄会让临时文件落到不该去的地方。需要重定向时显式设
#   PLATFORM_TMP_ROOT（测试注入、非标准部署都走这条路），而不是依赖外部 TMPDIR。
PLATFORM_TMP_ROOT="${PLATFORM_TMP_ROOT:-/tmp}"

# ── 工具/路径解析 ─────────────────────────────────────────────────────────

# platform_pkg_dest：当前套件的安装目录（target）。
#   群晖优先 SYNOPKG_PKGDEST；飞牛优先 TRIM_APPDEST；都没有则按 <包根>/<包名>/target 拼。
#   参数：$1 = 包名（可空，空则用 SYNOPKG_PKGNAME）
platform_pkg_dest() {
  local pkg_name="${1:-${SYNOPKG_PKGNAME:-}}"
  if [ -n "${SYNOPKG_PKGDEST:-}" ]; then printf '%s' "$SYNOPKG_PKGDEST"; return 0; fi
  if [ -n "${TRIM_APPDEST:-}" ]; then printf '%s' "$TRIM_APPDEST"; return 0; fi
  if [ -z "$pkg_name" ]; then return 1; fi
  if [ -d "$PLATFORM_FNOS_APPS_ROOT/$pkg_name" ]; then
    printf '%s' "$PLATFORM_FNOS_APPS_ROOT/$pkg_name/target"
  else
    printf '%s' "$PLATFORM_DSM_PKG_ROOT/$pkg_name/target"
  fi
}

# platform_pkg_var：当前套件的数据目录（跨版本的那个父目录）。
platform_pkg_var() {
  local pkg_name="${1:-${SYNOPKG_PKGNAME:-}}"
  if [ -n "${SYNOPKG_PKGVAR:-}" ]; then printf '%s' "$SYNOPKG_PKGVAR"; return 0; fi
  if [ -n "${TRIM_PKGVAR:-}" ]; then printf '%s' "$TRIM_PKGVAR"; return 0; fi
  if [ -z "$pkg_name" ]; then return 1; fi
  if [ -d "$PLATFORM_DSM_APPDATA_ROOT/$pkg_name" ]; then
    printf '%s' "$PLATFORM_DSM_APPDATA_ROOT/$pkg_name"
  else
    printf '%s' "$PLATFORM_FNOS_APPCENTER_ROOT/$pkg_name/var"
  fi
}

# platform_tmp_dir：建一个本次独占的临时目录并打印其路径。
#   替代原来写死的 /tmp/<固定名>.$$（并发下会互相踩，且 $$ 在不同 shell 里可能重合）。
#   失败即返回非零 —— 调用方必须处理，不要继续用空路径拼文件名。
platform_tmp_dir() {
  local prefix="${1:-dsh}"
  local dir
  dir="$(mktemp -d "$PLATFORM_TMP_ROOT/${prefix}.XXXXXX" 2>/dev/null)" || return 1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  printf '%s' "$dir"
}

# platform_tmp_file：建一个本次独占的临时文件并打印其路径（参数同 platform_tmp_dir）。
platform_tmp_file() {
  local prefix="${1:-dsh}"
  local file
  file="$(mktemp "$PLATFORM_TMP_ROOT/${prefix}.XXXXXX" 2>/dev/null)" || return 1
  [ -n "$file" ] && [ -f "$file" ] || return 1
  printf '%s' "$file"
}

# resolve_pnpm_entry：找到可直接交给 node 执行的 pnpm 入口（.mjs 或 .cjs）。
#   为什么需要：多个诊断脚本把 /root/.cache/node/corepack/v1/pnpm/<版本>/dist/pnpm.mjs 写死，
#   一旦 corepack 版本变化（11.7.0 → 11.8.x）就全部失效。
#   查找顺序：随包 pnpm → PATH 上的 pnpm（解析真实文件）→ corepack 缓存里最新的一个。
#   注意：返回值是「入口文件路径」，调用方仍应使用套件自带的 node 去执行它，避免用到系统旧版 node。
resolve_pnpm_entry() {
  local candidate
  for candidate in \
    "${SYNOPKG_PKGDEST:-}/tools/pnpm/dist/pnpm.mjs" \
    "${TRIM_APPDEST:-}/tools/pnpm/dist/pnpm.mjs" \
    "${DSH_DIR:-}/tools/pnpm/dist/pnpm.mjs" \
    "${DSH_DIR:-}/pnpm/dist/pnpm.mjs"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done

  candidate="$(command -v pnpm 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    # pnpm 通常是指向 dist/pnpm.cjs 的启动器；解析真实文件后再返回，保证 node 能直接跑
    candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  fi

  # corepack 缓存：不写死版本号，取字典序最后一个（版本号单调递增）
  local cache_root="${COREPACK_HOME:-${HOME:-/root}/.cache/node/corepack}"
  candidate="$(ls -1d "$cache_root"/v1/pnpm/*/dist/pnpm.mjs 2>/dev/null | sort -V | tail -1)"
  [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }

  return 1
}

# require_nonempty：断言变量非空，否则报错退出。
#   用于所有「拿不到就会拼出半截路径」的地方 —— 宁可失败，也不要让 /target 这种路径进删除/写入逻辑。
#   参数：$1 = 变量的值，$2 = 变量名（报错用）
require_nonempty() {
  if [ -z "${1:-}" ]; then
    echo "✗ 关键路径为空（${2:-未知变量}）—— 拒绝以空路径继续" >&2
    return 1
  fi
  return 0
}
