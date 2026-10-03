#!/usr/bin/env bash
#
# sync-github-release.sh —— 轮询 GitHub Releases，把项目自动发布的 spk/fpk 资产
#                          下载到本地 release/，按 tag 分类存放。
#
# 用法:
#   ./scripts/sync-github-release.sh                        # 前台跑一轮（默认单次）
#   ./scripts/sync-github-release.sh --loop 300             # 后台式轮询，每 300 秒一轮
#   ./scripts/sync-github-release.sh --tag dsh-v0.1.5-rc.2  # 只同步指定 tag
#   ./scripts/sync-github-release.sh --repo owner/name      # 指定仓库（默认 EIGHTfs/DeepSeekHarness-NAS）
#   ./scripts/sync-github-release.sh --log 路径/文件        # 指定日志文件（默认 release-sync.log）
#   ./scripts/sync-github-release.sh --start/--stop/--restart/--status   # 服务化启停（PID 在项目根）
#
# 策略:
#   通道: 版本与资产元信息走 api.github.com；下载走 API asset 端点
#         (Accept: application/octet-stream)，比 github.com 直链稳。
#   分类: 每个 release 独立目录 release/<tag>/，内放它发布的 *.spk / *.fpk。
#   增量: 已下载且大小==远端 size 的资产跳过，重复运行不重复下载。
#   token: 从 git-push 插件凭据文件读取（可被 $GITHUB_TOKEN 覆盖），不硬编码。
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_REPO="EIGHTfs/DeepSeekHarness-NAS"
DEFAULT_OUT="$PROJECT_ROOT/release"
DEFAULT_LOG="$SCRIPT_DIR/release-sync.log"
DEFAULT_INTERVAL=300
PID_FILE="$PROJECT_ROOT/DeepSeekHarness-NAS-release-sync.pid"

# ---------- token 解析（优先 $GITHUB_TOKEN，其次 git-push 凭据文件） ----------
TOKEN=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then TOKEN="$GITHUB_TOKEN"; fi
if [[ -z "$TOKEN" ]]; then
  for p in \
    "$HOME/.dsh/git-push/github-token" \
    "$PROJECT_ROOT/.dsh-home/.dsh/git-push/github-token" \
    "$PROJECT_ROOT/tools/git-push/github-token"; do
    if [[ -f "$p" ]]; then
      TOKEN="$(python3 -c "import sys;print(open(sys.argv[1]).read().strip())" "$p")"
      break
    fi
  done
fi

REPO="$DEFAULT_REPO"
OUT="$DEFAULT_OUT"
LOG_FILE="$DEFAULT_LOG"
INTERVAL="$DEFAULT_INTERVAL"
LOOP=0
TARGET_TAG=""

usage() { sed -n '2,14p' "$0"; }

daemon_is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}
start_daemon() {
  if daemon_is_running; then echo "已在运行 (pid $(cat "$PID_FILE"))"; exit 0; fi
  # stdout 丢弃：日志统一由子脚本的 log()（tee -a）落盘，避免与重定向双写
  nohup "$0" --loop "$INTERVAL" --repo "$REPO" --log "$LOG_FILE" >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
  echo "已启动守护 (pid $!) → $LOG_FILE（每 ${INTERVAL}s 轮询 $REPO）"
}
stop_daemon() {
  if ! daemon_is_running; then echo "未在运行"; rm -f "$PID_FILE"; exit 0; fi
  PID="$(cat "$PID_FILE")"
  kill -TERM "$PID" 2>/dev/null || true
  for _ in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  kill -KILL "$PID" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "已停止 (pid $PID)"
}
daemon_status() {
  if daemon_is_running; then echo "运行中 (pid $(cat "$PID_FILE"))"; else echo "未运行"; rm -f "$PID_FILE"; fi
}

# 单轮同步：委托给 Python（解析 releases → 增量筛选 → 用 urllib 带 token 下载）
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

sync_once() {
  log "── 开始同步 $REPO → $OUT ──"
  # shellcheck disable=SC2031
  TOKEN="$TOKEN" REPO="$REPO" OUT="$OUT" TAG_FILTER="$TARGET_TAG" \
    python3 - <<'PYEOF' 2>&1 | while IFS= read -r line; do log "$line"; done || true
import json, os, re, sys, time, urllib.request

TOKEN = os.environ.get("TOKEN", "")
REPO  = os.environ.get("REPO", "EIGHTfs/DeepSeekHarness-NAS")
OUT   = os.environ.get("OUT", "release")
TAG_FILTER = os.environ.get("TAG_FILTER", "")

def log(msg):
    print(time.strftime("%F %T") + " " + msg, flush=True)

def http_get(url, octet=False):
    req = urllib.request.Request(url, headers={"User-Agent": "dsh-release-sync"})
    if TOKEN:
        req.add_header("Authorization", "token " + TOKEN)
    if octet:
        req.add_header("Accept", "application/octet-stream")
    return urllib.request.urlopen(req, timeout=40)

try:
    with http_get(f"https://api.github.com/repos/{REPO}/releases?per_page=15") as r:
        releases = json.load(r)
except Exception as e:
    log(f"✗ 获取 releases 失败: {e}")
    sys.exit(0)

for rel in releases:
    tag = rel.get("tag_name") or ""
    if not tag:
        continue
    if TAG_FILTER and tag != TAG_FILTER:
        continue
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", tag)
    d = os.path.join(OUT, safe)
    os.makedirs(d, exist_ok=True)
    for a in rel.get("assets", []):
        name = a.get("name") or ""
        if not (name.endswith(".fpk") or name.endswith(".spk")):
            continue
        want = a.get("size") or 0
        dest = os.path.join(d, name)
        cur = os.path.getsize(dest) if os.path.isfile(dest) else 0
        if cur == want and want > 0:
            log(f"✓ [{tag}] {name} 已完整（跳过）")
            continue
        aid = a.get("id") or ""
        url = f"https://api.github.com/repos/{REPO}/releases/assets/{aid}"
        log(f"… [{tag}] {name} {cur}/{want} → 下载")
        ok = False
        for attempt in range(3):
            try:
                with http_get(url, octet=True) as r:
                    data = r.read()
                if want == 0 or len(data) == want:
                    tmp = dest + ".part"
                    with open(tmp, "wb") as f:
                        f.write(data)
                    os.replace(tmp, dest)
                    ok = True
                    break
                else:
                    log(f"  大小不符 {len(data)}!={want}，重试…")
            except Exception as e:
                log(f"  下载异常: {e}，重试…")
            time.sleep(3)
        log(f"✅ [{tag}] {name} 完整 ({os.path.getsize(dest) if os.path.isfile(dest) else 0} bytes)" if ok
            else f"❌ [{tag}] {name} 未完整（需重试）")
PYEOF
  log "── 本轮结束 ──"
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="${2:?--repo 需要一个值}"; shift 2 ;;
    --out)      OUT="${2:?--out 需要一个值}"; shift 2 ;;
    --log)      LOG_FILE="${2:?--log 需要一个值}"; shift 2 ;;
    --tag)      TARGET_TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --loop)     LOOP=1; INTERVAL="${2:-$DEFAULT_INTERVAL}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval 需要一个值}"; shift 2 ;;
    --start)    start_daemon; exit 0 ;;
    --stop)     stop_daemon; exit 0 ;;
    --restart)  stop_daemon; start_daemon; exit 0 ;;
    --status)   daemon_status; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$OUT"
mkdir -p "$(dirname "$LOG_FILE")"

if [[ "$LOOP" == "1" ]]; then
  trap 'echo "$(date "+%F %T") 收到退出信号，停止"; exit 0' TERM INT
  log "轮询守护启动: $REPO → $OUT（每 ${INTERVAL}s）日志: $LOG_FILE"
  while true; do
    sync_once || true
    sleep "$INTERVAL"
  done
else
  sync_once || true
fi