#!/usr/bin/env bash
# watch-official-local.sh —— 本机高频探活，弥补 GitHub schedule 被降频的问题。
#
# 背景：`.github/workflows/watch-official.yml` 的 cron 写的是每 30 分钟，但 GitHub 对
#   schedule 事件有降频与限流（低活跃仓库尤其明显），实测运行间隔约 8 小时 —— 官方发版后
#   可能要等几小时才出包。本脚本由本机系统定时器（DSM 任务计划）高频调用，把「判定」跑勤，
#   从而把对齐延迟压到分钟级。
#
# 设计要点：
#   · 判定逻辑不在这里另立一套：本脚本只做「前置过滤」（省 Actions 分钟），命中后派发
#     watch-official，最终判定仍由 GitHub 侧那份唯一实现完成 —— 避免两套判据漂移。
#   · 参数全部是脚本内常量（间隔、冷却、仓库、日志上限）；凭据同样是脚本内常量，
#     **入库版本留空**，本机部署时手动填入（见 DEPLOYMENT 注释），提交时不要带上真实值。
#   · 幂等：重复运行不会造成重复构建 —— 命中条件本身已经含「无构建在跑」与「够冷却」。
#   · 无凭据也能跑：GitHub 匿名读接口有独立配额（远小于认证配额，但足够本脚本一轮 3~4 次
#     读取）。所以「无凭据」只影响最后那一步派发，读取与判定一律照常进行；三类结果分别记
#     日志：正常 / 触发限额 / 真实失败 —— 不要把限额误当成脚本坏了。
#
# 用法：
#   ./watch-official-local.sh                # 正常一轮（判定 + 必要时派发）
#   ./watch-official-local.sh --dry-run      # 只判定并打印结论，不派发
#   ./watch-official-local.sh --print-cron   # 打印应注册到系统定时器的命令
#
# 退出码：0 = 本轮正常结束（含各种跳过）；1 = 真实失败（网络/HTTP 异常）；2 = 参数错误
#
# DEPLOYMENT（本机部署，一次性）：
#   1) 把下面 GITHUB_TOKEN 常量改成真实 token（需要 actions:write 权限）
#      不填也能跑：读取与判定照常，只是无法派发（日志会写明）
#   2) 执行本脚本的 --print-cron，把输出注册到 DSM 任务计划（root 身份）
#   3) 防误提交：git update-index --skip-worktree scripts/watch-official-local.sh
#      （之后本机对 token 那一行的改动不会进入提交；CI 还有一道守卫兜底扫描）

set -uo pipefail

# ── 常量（按部署方口径刻意写死在脚本里，不读环境变量/配置文件）──────────────
readonly OFFICIAL_REPO_SLUG="deepseek-ai/deepseek-harness"   # 上游：官方 dsh
readonly MIRROR_REPO_SLUG="EIGHTfs/DeepSeekHarness-NAS"      # 本仓：打包镜像
readonly POLL_INTERVAL_MINUTES=15                            # 探测周期；须与系统定时器一致
readonly BUILD_COOLDOWN_SECONDS=$((6 * 3600))                # 成功后冷却：与 GitHub 版口径一致
readonly LOG_MAX_LINES=500                                   # 日志保留行数上限
readonly GITHUB_TOKEN=""                                     # 入库留空；本机部署时填入（勿提交）
readonly API_BASE="https://api.github.com"

# ── 运行时状态 ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FALLBACK_DIR="${TMPDIR:-/tmp}"
DRY_RUN=0
PRINT_CRON=0

# 每次请求后由 api_fetch 回填：HTTP 状态码、响应体路径、限额剩余、限额重置时刻
API_HTTP_CODE=0
API_BODY_FILE=""
API_RATE_REMAINING=""
API_RATE_RESET=""
WORK_DIR=""

for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --print-cron) PRINT_CRON=1 ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $argument（支持 --dry-run / --print-cron / --help）" >&2; exit 2 ;;
  esac
done

# 系统定时器里 PATH 往往很干净，显式补上常见路径
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

WORK_DIR="$(mktemp -d 2>/dev/null || printf '%s' "$LOG_FALLBACK_DIR")"
API_BODY_FILE="${WORK_DIR}/api-body.json"
API_HEADERS_FILE="${WORK_DIR}/api-headers.txt"

cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null
}
trap cleanup EXIT

# ── 日志：优先写应用数据目录（持久、可查），不可写则退到 tmp ───────────────
# `/var/packages/<包>/var` 是符号链接，readlink -f 解析出来是【包级】数据目录
# （版本子目录由启动脚本自己拼，链接本身不含版本号）——日志放这里跨版本通用，
# 不会像版本目录那样每升级一次就多一份。不可写时退回 $TMPDIR。
resolve_log_file() {
  local package_var="/var/packages/DeepSeekHarness-NAS/var"
  local resolved_var candidate_dir
  resolved_var="$(readlink -f "$package_var" 2>/dev/null || printf '%s' "$package_var")"
  for candidate_dir in "$resolved_var" "${LOG_FALLBACK_DIR}"; do
    [ -n "$candidate_dir" ] || continue
    [ -d "$candidate_dir" ] || continue
    [ -w "$candidate_dir" ] || continue
    printf '%s' "${candidate_dir%/}/watch-official-local.log"
    return 0
  done
  printf '%s' "${LOG_FALLBACK_DIR}/watch-official-local.log"
}

LOG_FILE="$(resolve_log_file)"

log_line() {
  local stamp
  stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s %s\n' "$stamp" "$*" >>"$LOG_FILE" 2>/dev/null || true
  printf '%s\n' "$*"
}

trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  local current_lines
  current_lines="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  if [ "${current_lines:-0}" -gt "$LOG_MAX_LINES" ]; then
    if tail -n "$LOG_MAX_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null; then
      mv -f "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || rm -f "${LOG_FILE}.tmp" 2>/dev/null
    fi
  fi
}

# ── --print-cron：把「周期只有一个真相源」落到可复制的注册命令上 ───────────
if [ "$PRINT_CRON" = "1" ]; then
  cat <<EOF
探测周期常量：每 ${POLL_INTERVAL_MINUTES} 分钟（本文件 POLL_INTERVAL_MINUTES）

DSM 任务计划（root 身份，图形界面：控制面板 → 任务计划 → 新增 → 计划的任务 → 用户定义的脚本）：
  名称      watch-official-local
  用户      root
  计划      每天 → 重复：每 ${POLL_INTERVAL_MINUTES} 分钟 → 首次运行 00:00
  命令      ${SCRIPT_DIR}/watch-official-local.sh

命令行等价写法（不同 DSM 版本参数有差异，先跑 synoschedtask --help 核对）：
  /usr/syno/bin/synoschedtask --add \\
      --name "watch-official-local" --user root \\
      --schedule "*/${POLL_INTERVAL_MINUTES} * * * *" \\
      --command "${SCRIPT_DIR}/watch-official-local.sh"

Linux 通用（crontab -e）：
  */${POLL_INTERVAL_MINUTES} * * * * ${SCRIPT_DIR}/watch-official-local.sh >/dev/null 2>&1
EOF
  exit 0
fi

# ── HTTP 层：把「状态码 / 限额头」都取回来，供上层区分类别 ─────────────────
api_fetch() {
  # api_fetch <path> [--with-token]
  local path="$1" with_token="${2:-}" code
  if [ "$with_token" = "--with-token" ] && [ -n "$GITHUB_TOKEN" ]; then
    code="$(timeout 25 curl -sS --max-time 20 -o "$API_BODY_FILE" -D "$API_HEADERS_FILE" -w '%{http_code}' \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}${path}" 2>/dev/null)" || code="000"
  else
    code="$(timeout 25 curl -sS --max-time 20 -o "$API_BODY_FILE" -D "$API_HEADERS_FILE" -w '%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}${path}" 2>/dev/null)" || code="000"
  fi
  API_HTTP_CODE="${code:-000}"
  API_RATE_REMAINING="$(grep -i '^x-ratelimit-remaining:' "$API_HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)"
  API_RATE_RESET="$(grep -i '^x-ratelimit-reset:' "$API_HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)"
  [ -n "$API_BODY_FILE" ] && [ -f "$API_BODY_FILE" ] || : >"${API_BODY_FILE}.empty"
  return 0
}

# 把响应体里的一个顶层字段取出来（取不到输出空）
body_field() {
  python3 -c 'import sys,json
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], "") or "")
except Exception:
    print("")' "$API_BODY_FILE" "$1" 2>/dev/null
}

body_first_release_tag() {
  python3 -c 'import sys,json
try:
    releases=json.load(open(sys.argv[1]))
    print(releases[0].get("tag_name","") if isinstance(releases,list) and releases else "")
except Exception:
    print("")' "$API_BODY_FILE" 2>/dev/null
}

body_first_run_time() {
  python3 -c 'import sys,json
try:
    runs=json.load(open(sys.argv[1])).get("workflow_runs") or [{}]
    print(runs[0].get("updated_at") or runs[0].get("created_at") or "")
except Exception:
    print("")' "$API_BODY_FILE" 2>/dev/null
}

body_run_count() {
  python3 -c 'import sys,json
try:
    print(len(json.load(open(sys.argv[1])).get("workflow_runs") or []))
except Exception:
    print(0)' "$API_BODY_FILE" 2>/dev/null
}

# 限额是否已经打满：403/429 且剩余 0，或带 retry-after
is_rate_limited() {
  case "$API_HTTP_CODE" in
    403|429)
      if [ "${API_RATE_REMAINING:-1}" = "0" ]; then return 0; fi
      grep -qi '^retry-after:' "$API_HEADERS_FILE" 2>/dev/null && return 0
      # 第二常见的 403 原因是权限不足（例如匿名/无 actions:write 去派发），不算限额
      return 1 ;;
    *) return 1 ;;
  esac
}

rate_limit_hint() {
  local reset_text="未知"
  if [ -n "${API_RATE_RESET:-}" ]; then
    reset_text="$(date -u -d "@${API_RATE_RESET}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$API_RATE_RESET")"
  fi
  printf '剩余=%s 重置=%s' "${API_RATE_REMAINING:-?}" "$reset_text"
}

# 统一出口：把「限额 / 失败」区分开，两者都不算脚本自身出错
finish_rate_limited() {
  log_line "触发限额（不是脚本故障）：$1 → $(rate_limit_hint)｜下一轮会自然恢复"
  trim_log
  exit 0
}

finish_failure() {
  log_line "失败：$1（HTTP ${API_HTTP_CODE}）"
  trim_log
  exit 1
}

# ── ① 官方最新 tag：复用仓内脚本（它已处理「只认 tag、不下载」） ─────────────
OFFICIAL_TAG=""
if [ -x "${SCRIPT_DIR}/fetch-dsh-latest.sh" ]; then
  OFFICIAL_TAG="$(timeout 60 bash "${SCRIPT_DIR}/fetch-dsh-latest.sh" --print-tag 2>/dev/null | tail -1)"
fi
if [ -z "$OFFICIAL_TAG" ]; then
  # 退路：直接问 API（不依赖仓内脚本）
  api_fetch "/repos/${OFFICIAL_REPO_SLUG}/releases?per_page=1" --with-token
  is_rate_limited && finish_rate_limited "读取官方 release 列表"
  case "$API_HTTP_CODE" in
    2??) OFFICIAL_TAG="$(body_first_release_tag)" ;;
    *) finish_failure "读取官方 release 列表" ;;
  esac
fi

if [ -z "$OFFICIAL_TAG" ]; then
  log_line "跳过：官方 release 列表为空（上游可能还没有 Release）"
  trim_log
  exit 0
fi

# ── ② 本仓最新 Release tag（已发布 = 已对齐的那个版本） ────────────────────
MIRROR_TAG=""
api_fetch "/repos/${MIRROR_REPO_SLUG}/releases/latest" --with-token
is_rate_limited && finish_rate_limited "读取本仓最新 Release"
case "$API_HTTP_CODE" in
  2??) MIRROR_TAG="$(body_field tag_name)" ;;
  404)
    # 本仓把最新 Release 标成 prerelease 时 /releases/latest 会 404 → 退到列表首条
    api_fetch "/repos/${MIRROR_REPO_SLUG}/releases?per_page=1" --with-token
    is_rate_limited && finish_rate_limited "读取本仓 release 列表"
    case "$API_HTTP_CODE" in
      2??) MIRROR_TAG="$(body_first_release_tag)" ;;
      *) finish_failure "读取本仓 release 列表" ;;
    esac ;;
  *) finish_failure "读取本仓最新 Release" ;;
esac

log_line "官方=${OFFICIAL_TAG} 本仓=${MIRROR_TAG:-（无 Release）}"

if [ "$OFFICIAL_TAG" = "$MIRROR_TAG" ]; then
  log_line "结论：已对齐，无需动作"
  trim_log
  exit 0
fi

# ── ③ 有构建在跑就不插队（build.yml 是 cancel-in-progress，插队会取消它） ──
api_fetch "/repos/${MIRROR_REPO_SLUG}/actions/workflows/build.yml/runs?status=in_progress&per_page=1" --with-token
is_rate_limited && finish_rate_limited "查询在跑的构建"
case "$API_HTTP_CODE" in
  2??) RUNNING_COUNT="$(body_run_count)" ;;
  *) finish_failure "查询在跑的构建" ;;
esac
if [ "${RUNNING_COUNT:-0}" != "0" ]; then
  log_line "结论：已有构建在跑，本次跳过（不插队）"
  trim_log
  exit 0
fi

# ── ④ 成功后冷却：与 GitHub 版同为 6 小时 ────────────────────────────────
api_fetch "/repos/${MIRROR_REPO_SLUG}/actions/workflows/build.yml/runs?status=success&per_page=1" --with-token
is_rate_limited && finish_rate_limited "查询上次成功构建"
case "$API_HTTP_CODE" in
  2??) LAST_SUCCESS_AT="$(body_first_run_time)" ;;
  *) finish_failure "查询上次成功构建" ;;
esac

if [ -n "${LAST_SUCCESS_AT:-}" ]; then
  LAST_SUCCESS_EPOCH="$(date -u -d "$LAST_SUCCESS_AT" +%s 2>/dev/null || echo 0)"
  NOW_EPOCH="$(date -u +%s)"
  if [ "${LAST_SUCCESS_EPOCH:-0}" -gt 0 ]; then
    AGE_SECONDS=$((NOW_EPOCH - LAST_SUCCESS_EPOCH))
    if [ "$AGE_SECONDS" -lt "$BUILD_COOLDOWN_SECONDS" ]; then
      log_line "结论：距上次成功构建仅 $((AGE_SECONDS / 60)) 分钟（冷却 $((BUILD_COOLDOWN_SECONDS / 60)) 分钟）→ 跳过"
      trim_log
      exit 0
    fi
  fi
fi

# ── ⑤ 需要派发 ─────────────────────────────────────────────────────────
# 派发是写操作，匿名不能做（匿名只有读配额）；这与「读不到」是两回事，日志要分开写
if [ -z "$GITHUB_TOKEN" ]; then
  log_line "结论：需要构建，但脚本内 GITHUB_TOKEN 为空 → 只做探测、不派发（填入即可自动派发）"
  trim_log
  exit 0
fi

DISPATCH_PATH="/repos/${MIRROR_REPO_SLUG}/actions/workflows/watch-official.yml/dispatches"
if [ "$DRY_RUN" = "1" ]; then
  log_line "结论：需要构建（dry-run，未实际派发）→ POST ${API_BASE}${DISPATCH_PATH}"
  trim_log
  exit 0
fi

DISPATCH_CODE="$(timeout 25 curl -sS -o "$API_BODY_FILE" -D "$API_HEADERS_FILE" -w '%{http_code}' --max-time 20 \
  -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d '{"ref":"main"}' \
  "${API_BASE}${DISPATCH_PATH}" 2>/dev/null)" || DISPATCH_CODE="000"
API_HTTP_CODE="${DISPATCH_CODE:-000}"
API_RATE_REMAINING="$(grep -i '^x-ratelimit-remaining:' "$API_HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)"
API_RATE_RESET="$(grep -i '^x-ratelimit-reset:' "$API_HEADERS_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -1)"

case "$API_HTTP_CODE" in
  204) log_line "已派发 watch-official（HTTP 204）：官方 ${OFFICIAL_TAG} ≠ 本仓 ${MIRROR_TAG}" ;;
  *)
    if is_rate_limited; then
      finish_rate_limited "派发 watch-official"
    fi
    finish_failure "派发 watch-official" ;;
esac
trim_log
