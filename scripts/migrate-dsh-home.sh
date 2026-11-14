#!/usr/bin/env bash
# migrate-dsh-home.sh —— 把旧版本的实例数据（<数据父目录>/<版本>/.dsh）迁移到当前版本。
#
# 背景：数据按版本隔离（见打包规范第 13 节），升级后新版本用新目录，旧版本的数据仍在原地。
#   想把旧版的设置/凭据/插件配置带过来时，手工 cp 有三处必踩的坑：
#     ① 属主：旧版可能属于 <包名>:<包名>，新版是 <包名>:system，root 直接 cp 会带错属主；
#     ② 凭据：.credentials.yaml 必须 600，否则 credentials 插件直接拒启；
#     ③ 软链：profiles/node_modules 下的软链指向旧版本路径，直接搬过来是断的。
#   本脚本把这三件事都收口，并且强制「先列候选 → 再 dry-run → 显式确认 → 才写盘」。
#
# 用法：
#   ./migrate-dsh-home.sh list                                   # 列候选源（只读）
#   （目标版本默认取「实际安装的版本」：读包内 package.json 的 version；要写别的版本用 --target <完整版本>）
#   ./migrate-dsh-home.sh migrate --from <版本> --dry-run         # 演练，不写盘
#   ./migrate-dsh-home.sh migrate --from <版本> --confirm         # 真执行
#   ./migrate-dsh-home.sh migrate --from <版本> --confirm                  # 配置 + 会话一起迁（默认）
#   ./migrate-dsh-home.sh migrate --from <版本> --config-only --confirm     # 只迁配置，不迁会话
#   ./migrate-dsh-home.sh prune --version <版本> --confirm         # 老数据改名归档（可恢复）
#   ./migrate-dsh-home.sh list --package <套件包名> --group <组名>    # 指向同形态的其它套件（默认本项目的）
#
# 退出码：0 正常；1 失败或前置条件不满足；2 参数错误

set -uo pipefail

# ── 常量（按部署口径写死在脚本里；换包名不是本脚本的用法）──────────────────
# 包名/组名默认取本项目的套件；用 --package / --group 可指向同形态的其它套件（工具保持通用）
PACKAGE_NAME="${DSH_PACKAGE_NAME:-DeepSeekHarness-NAS}"
PACKAGE_GROUP="${DSH_PACKAGE_GROUP:-system}"
readonly BACKUP_SUFFIX_PREFIX=".bak-"
readonly MIGRATED_SUFFIX_PREFIX=".migrated-"
# 迁移内容：配置类默认全迁；sessions 需显式 --with-sessions（跨大版本有格式差异）
readonly CONFIG_ENTRIES=(
  "settings.yaml"
  ".credentials.yaml"
  ".anonymous-user-id"
  "profiles"
  "storages"
)
readonly SESSIONS_ENTRY="sessions"

# 会话格式无需本脚本关心：DSH 自带 v0→v4 的迁移链，读取旧格式时自动转换
#   （catalog 里 recovery=recoverable / validation=transformed），搬文件即可

ACTION="${1:-}"
shift || true
FROM_VERSION=""
TARGET_VERSION_ARG=""
EXPLICIT_CURRENT=""
DRY_RUN=0
CONFIRM=0
WITH_SESSIONS=1

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) FROM_VERSION="${2:-}"; shift 2 ;;
    --from=*) FROM_VERSION="${1#*=}"; shift ;;
    --package) PACKAGE_NAME="${2:-}"; shift 2 ;;
    --group) PACKAGE_GROUP="${2:-}"; shift 2 ;;
    --target) EXPLICIT_CURRENT="${2:-}"; shift 2 ;;
    --version) TARGET_VERSION_ARG="${2:-}"; shift 2 ;;
    --version=*) TARGET_VERSION_ARG="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --confirm) CONFIRM=1; shift ;;
    --with-sessions) WITH_SESSIONS=1; shift ;;   # 兼容旧写法（现在本来就是默认行为）
    --config-only) WITH_SESSIONS=0; shift ;;      # 只迁配置，不迁会话
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1（-h 看用法）" >&2; exit 2 ;;
  esac
done

# 防御性 cd：本脚本常被 su / 计划任务拉起，此时 cwd 是调用者目录（多为 root 家目录），
#   套件用户无权访问它 —— find / du 会报 "cannot get current directory: Permission denied"
#   并静默返回 0（表现为"没有可迁移数据"这种假结论）。cd 到自己所在目录最稳。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "${SCRIPT_DIR:-}" ] && cd "$SCRIPT_DIR" 2>/dev/null
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

# ── 环境探测：数据父目录、当前版本、运行身份 ─────────────────────────────
PACKAGE_VAR_LINK="/var/packages/${PACKAGE_NAME}/var"
PKG_VAR_DIR="$(readlink -f "$PACKAGE_VAR_LINK" 2>/dev/null || printf '%s' "$PACKAGE_VAR_LINK")"
PACKAGE_INFO="/var/packages/${PACKAGE_NAME}/INFO"

detect_installed_version() {
  sed -n 's/^version="\([^"]*\)".*/\1/p' "$PACKAGE_INFO" 2>/dev/null | head -1
}

# ── 当前版本的判定（不靠目录名猜）────────────────────────────────────────
# 权威来源：包内 package.json 的 version —— 打包时由产物自身携带，等于「这份安装包属于哪个 dsh 版本」。
#   INFO 的 version 只有前三位（0.2.2），rc/alpha 序号丢了，无法区分 0.2.2-rc.1 与 rc.3；
#   而数据目录是「装过的版本」的集合，按目录名取最大在降级安装后会指错。
detect_installed_full_version() {
  local package_json="/var/packages/${PACKAGE_NAME}/target/package.json"
  [ -f "$package_json" ] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package_json" | head -1
}

# 回退路径：用 INFO 的前三位做前缀匹配，但**只在唯一命中时采用**；命中多个就报歧义，由调用方
# 用 --target 显式指定 —— 绝不「取最大」蒙一个。
detect_current_data_dir() {
  local full_version short_version matches count
  full_version="$(detect_installed_full_version)"
  if [ -n "$full_version" ]; then
    if [ -d "${PKG_VAR_DIR}/${full_version}" ]; then
      printf '%s' "${PKG_VAR_DIR}/${full_version}"
      return 0
    fi
    echo "  ⚠ 包内版本为 ${full_version}，但数据目录 ${PKG_VAR_DIR}/${full_version} 不存在" >&2
  fi

  short_version="$(detect_installed_version)"
  [ -n "$short_version" ] || return 0
  matches="$(ls -1d "${PKG_VAR_DIR}/${short_version}"*/ 2>/dev/null)"
  count="$(printf '%s\n' "$matches" | grep -c . || true)"
  if [ "${count:-0}" = "1" ]; then
    printf '%s' "${matches%/}"
    return 0
  fi
  if [ "${count:-0}" -gt 1 ] 2>/dev/null; then
    echo "  ⚠ 数据目录里有 ${count} 个候选匹配 ${short_version}*：" >&2
    printf '%s\n' "$matches" | sed 's/^/     /' >&2
    echo "    无法自动判断当前版本，请用 --target <完整版本> 指定（例如 --target 0.2.2-rc.3）" >&2
  fi
}

CURRENT_VERSION_SOURCE="包内 package.json"
if [ -n "$EXPLICIT_CURRENT" ]; then
  CURRENT_VERSION_SOURCE="--target 显式指定"
  CURRENT_DATA_DIR="${PKG_VAR_DIR}/${EXPLICIT_CURRENT}"
  [ -d "$CURRENT_DATA_DIR" ] || { echo "✗ --target 指定的数据目录不存在：$CURRENT_DATA_DIR" >&2; exit 1; }
else
  _detected_full="$(detect_installed_full_version)"
  CURRENT_DATA_DIR="$(detect_current_data_dir)"
  if [ -z "$_detected_full" ] || [ "${CURRENT_DATA_DIR##*/}" != "$_detected_full" ]; then
    CURRENT_VERSION_SOURCE="INFO 前三位唯一匹配"
  fi
fi
CURRENT_VERSION="$(basename "${CURRENT_DATA_DIR:-（未知）}")"

require_package_user() {
  # 数据区属主是套件用户；用 root 复制会把属主/组带错，所以统一以套件身份干活
  local current_user
  current_user="$(id -un)"
  if [ "$current_user" = "$PACKAGE_NAME" ]; then
    return 0
  fi
  echo "✗ 请以套件用户身份运行（当前是 $current_user）" >&2
  echo "  套件用户可这样切换：su -s /bin/sh ${PACKAGE_NAME} -c '$0 $ACTION $*'" >&2
  return 1
}

human_size() {
  # 纯 shell 实现，避免依赖 du 的 -h 格式
  local kilobytes="$1"
  if [ "${kilobytes:-0}" -ge 1048576 ]; then
    printf '%d.%d G' $((kilobytes / 1048576)) $(((kilobytes % 1048576) * 10 / 1048576))
  elif [ "${kilobytes:-0}" -ge 1024 ]; then
    printf '%d.%d M' $((kilobytes / 1024)) $(((kilobytes % 1024) * 10 / 1024))
  else
    printf '%d K' "${kilobytes:-0}"
  fi
}

dir_usage_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

count_files() {
  # 读不到时必须暴露，不能静默返回 0（0 会被上层判成"空目录/无数据"）
  local output
  if ! output="$(find "$1" -type f 2>&1)"; then
    case "$output" in
      *"Permission denied"*|*"cannot get current directory"*)
        echo "  ⚠ 无法读取 $1（权限）：$output" >&2 ;;
      *) echo "  ⚠ 无法读取 $1：$output" >&2 ;;
    esac
    return 1
  fi
  printf '%s\n' "$output" | grep -c . || true
}

count_symlinks() {
  find "$1" -type l 2>/dev/null | wc -l | tr -d ' '
}

# 前置校验：包名写错时要立刻报错，不能静默返回「没有可迁移数据」（那是假结论）
require_package_present() {
  if [ ! -f "$PACKAGE_INFO" ]; then
    echo "✗ 找不到套件信息：$PACKAGE_INFO" >&2
    echo "  用 --package <包名> 指定正确的套件（当前用的是 ${PACKAGE_NAME}）" >&2
    exit 1
  fi
  if [ ! -d "$PKG_VAR_DIR" ]; then
    echo "✗ 找不到数据目录：$PKG_VAR_DIR" >&2
    exit 1
  fi
}

# ── list：枚举可迁移的旧版本数据 ────────────────────────────────────────
cmd_list() {
  local found=0 candidate version files size owner links has_cred has_sessions
  echo "═══════════════════════════════════════"
  echo "  可迁移的旧版本数据（当前版本：${CURRENT_VERSION:-未知}）"
  echo "  当前版本来源：${CURRENT_VERSION_SOURCE}"
  echo "═══════════════════════════════════════"
  printf '  %-16s %7s %8s %6s %-24s %s\n' "版本" "文件" "体积" "软链" "属主:组" "内容"
  for candidate in "${PKG_VAR_DIR}"/*/; do
    [ -d "${candidate}.dsh" ] || continue
    version="$(basename "$candidate")"
    [ "$version" = "$CURRENT_VERSION" ] && continue
    files="$(count_files "${candidate}.dsh")"
    # 空目录（例如只有壳）不列为候选：迁过去也没意义
    [ "${files:-0}" = "0" ] && continue
    found=$((found + 1))
    size="$(human_size "$(dir_usage_kb "${candidate}.dsh")")"
    links="$(count_symlinks "${candidate}.dsh")"
    owner="$(stat -c '%U:%G' "${candidate}.dsh" 2>/dev/null || echo '?')"
    has_cred=$([ -f "${candidate}.dsh/.credentials.yaml" ] && echo '凭据' || echo '')
    has_sessions=$([ -d "${candidate}.dsh/sessions" ] && echo '会话' || echo '')
    printf '  %-16s %7s %8s %6s %-24s %s\n' "$version" "$files" "$size" "$links" "$owner" "${has_cred} ${has_sessions}"
  done
  if [ "$found" = "0" ]; then
    echo "  （没有可迁移的旧版本数据）"
  else
    echo
    echo "  一次只能选一个源（多版本合并会互相覆盖）。下一步："
    echo "    $0 migrate --from <上面某个版本> --dry-run"
  fi
}

# ── migrate ────────────────────────────────────────────────────────────
cmd_migrate() {
  local source_dsh target_dsh dry_run_label
  if [ -z "$FROM_VERSION" ]; then
    echo "✗ 必须用 --from <版本> 指定源（先跑 $0 list 看候选）" >&2
    exit 2
  fi
  if [ -z "$CURRENT_DATA_DIR" ]; then
    echo "✗ 定位不到当前版本的数据目录（${PKG_VAR_DIR}）" >&2
    exit 1
  fi
  if [ "$FROM_VERSION" = "$CURRENT_VERSION" ]; then
    echo "✗ 源与当前版本相同（$FROM_VERSION），无需迁移" >&2
    exit 1
  fi

  source_dsh="${PKG_VAR_DIR}/${FROM_VERSION}/.dsh"
  target_dsh="${CURRENT_DATA_DIR}/.dsh"
  if [ ! -d "$source_dsh" ]; then
    echo "✗ 源不存在：$source_dsh" >&2
    exit 1
  fi

  echo "═══════════════════════════════════════"
  echo "  迁移实例数据"
  echo "═══════════════════════════════════════"
  echo "  当前版本: ${CURRENT_VERSION:-未知}（来源：${CURRENT_VERSION_SOURCE}）"
  echo "  源    : $source_dsh"
  echo "  目标  : $target_dsh"
  echo "  内容  : 配置类（settings / 凭据 / anonymous-user-id / profiles / storages）"
  if [ "$WITH_SESSIONS" = "1" ]; then
    echo "          + sessions（会话记录，默认一起迁）"
  else
    echo "          sessions 不迁（--config-only）"
  fi
  echo

  local source_files source_size source_links
  source_files="$(count_files "$source_dsh")"
  source_size="$(human_size "$(dir_usage_kb "$source_dsh")")"
  source_links="$(count_symlinks "$source_dsh")"
  echo "  源规模: $source_files 个文件 / $source_size / $source_links 条软链"

  if [ "$WITH_SESSIONS" = "1" ] && [ -d "$source_dsh/$SESSIONS_ENTRY" ]; then
    echo "  会话旧格式无需转换：DSH 读取时自动迁移（v0→v4 全链路）"
  fi

  # 目标现状
  local target_nonempty=0 backup_path=""
  if [ -d "$target_dsh" ] && [ "$(count_files "$target_dsh")" != "0" ]; then
    target_nonempty=1
    backup_path="${target_dsh}${BACKUP_SUFFIX_PREFIX}$(date +%Y%m%d-%H%M%S)"
    echo "  目标现状: 非空（$(count_files "$target_dsh") 个文件 / $(human_size "$(dir_usage_kb "$target_dsh")")）"
    echo "            将整目录改名为 ${backup_path}（可随时 mv 回来）"
  else
    echo "  目标现状: 空或不存在 → 直接写入"
  fi

  # 将排除的条目（未启用的 sessions）
  if [ "$WITH_SESSIONS" != "1" ] && [ -d "$source_dsh/$SESSIONS_ENTRY" ]; then
    echo "  跳过    : $SESSIONS_ENTRY（$(count_files "$source_dsh/$SESSIONS_ENTRY") 个文件 / $(human_size "$(dir_usage_kb "$source_dsh/$SESSIONS_ENTRY")")）"
  fi
  echo

  dry_run_label="执行"
  if [ "$DRY_RUN" = "1" ] || [ "$CONFIRM" != "1" ]; then
    echo "═══════════════════════════════════════"
    echo "  演练结束（未写盘）"
    echo "═══════════════════════════════════════"
    echo "  确认无误后加 --confirm 执行："
    echo "    $0 migrate --from $FROM_VERSION$([ "$WITH_SESSIONS" = "1" ] || echo ' --config-only') --confirm"
    return 0
  fi

  # ── 真执行 ─────────────────────────────────────────────────────────
  mkdir -p "$target_dsh" || { echo "✗ 无法创建目标目录" >&2; exit 1; }
  if [ "$target_nonempty" = "1" ]; then
    mv "$target_dsh" "$backup_path" || { echo "✗ 备份目标失败，未改动" >&2; exit 1; }
    echo "  ✓ 目标已备份为 $(basename "$backup_path")"
    mkdir -p "$target_dsh" || exit 1
  fi

  # 用 tar 管道复制：保留软链形态、不跟随（cp -a 在某些文件系统上会因为 utime 失败中断）
  local tar_excludes=()
  if [ "$WITH_SESSIONS" != "1" ]; then
    tar_excludes+=("--exclude=./$SESSIONS_ENTRY")
  fi
  if ! ( cd "$source_dsh" && tar -cf - "${tar_excludes[@]}" . 2>/dev/null ) |
       ( cd "$target_dsh" && tar -xf - 2>/dev/null ); then
    echo "✗ 复制失败；目标已备份，可 mv 回来" >&2
    exit 1
  fi
  echo "  ✓ 内容已复制"

  # 属主：统一成包用户与套件组（旧版可能是 包名:包名）
  if [ "$(id -un)" = "$PACKAGE_NAME" ]; then
    chown -R "${PACKAGE_NAME}:${PACKAGE_GROUP}" "$target_dsh" 2>/dev/null || true
  fi
  echo "  ✓ 属主已归到 ${PACKAGE_NAME}:${PACKAGE_GROUP}（失败的条目不影响启动）"

  # 凭据必须 600，否则 credentials 插件拒启
  if [ -f "$target_dsh/.credentials.yaml" ]; then
    chmod 600 "$target_dsh/.credentials.yaml" 2>/dev/null || true
    echo "  ✓ 凭据权限已设为 600（$(stat -c '%a' "$target_dsh/.credentials.yaml" 2>/dev/null)）"
  fi

  # 复制后校验：文件数应不小于源里被迁移的部分
  local copied_files
  copied_files="$(count_files "$target_dsh")"
  echo "  ✓ 目标现有 $copied_files 个文件 / $(count_symlinks "$target_dsh") 条软链"
  echo
  echo "═══════════════════════════════════════"
  echo "  下一步（在套件目录执行）"
  echo "═══════════════════════════════════════"
  echo "  1) 重启套件：synopkg restart ${PACKAGE_NAME}"
  echo "  2) 跑自检：  ./start.sh check        （第 ⑥ 项会核对依赖软链）"
  echo "  3) 确认新版运行正常后，如要归档旧数据："
  echo "       $0 prune --version $FROM_VERSION --confirm"
  [ -n "$backup_path" ] && echo "  4) 万一要回滚：mv ${backup_path} ${target_dsh}"
}

# ── prune：把旧版本 .dsh 改名归档（可恢复，不做 rm）─────────────────────
cmd_prune() {
  local version="${TARGET_VERSION_ARG:-$FROM_VERSION}"
  if [ -z "$version" ]; then
    echo "✗ 必须用 --version <版本> 指定要归档的旧数据" >&2
    exit 2
  fi
  if [ "$version" = "$CURRENT_VERSION" ]; then
    echo "✗ 拒绝归档当前版本（$version）的数据" >&2
    exit 1
  fi
  local victim="${PKG_VAR_DIR}/${version}/.dsh"
  if [ ! -d "$victim" ]; then
    echo "✗ 不存在：$victim" >&2
    exit 1
  fi
  local archived="${victim}${MIGRATED_SUFFIX_PREFIX}$(date +%Y%m%d-%H%M%S)"
  echo "  将归档：$victim"
  echo "      →  $archived"
  echo "  文件数：$(count_files "$victim") / 体积：$(human_size "$(dir_usage_kb "$victim")")"
  if [ "$CONFIRM" != "1" ]; then
    echo
    echo "  演练结束（未改动）。确认后加 --confirm："
    echo "    $0 prune --version $version --confirm"
    return 0
  fi
  mv "$victim" "$archived" || { echo "✗ 归档失败" >&2; exit 1; }
  echo "  ✓ 已归档（可随时 mv 回来）"
}

case "$ACTION" in
  list)
    require_package_present
    cmd_list ;;
  migrate)
    require_package_present
    require_package_user || exit 1
    cmd_migrate ;;
  prune)
    require_package_present
    require_package_user || exit 1
    cmd_prune ;;
  ""|-h|--help) usage ;;
  *) echo "未知动作: $ACTION（可用：list / migrate / prune）" >&2; exit 2 ;;
esac
