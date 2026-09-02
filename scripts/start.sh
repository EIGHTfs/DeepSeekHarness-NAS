#!/bin/bash
# ============================================================
#  DSH 实例启动脚本 (dsh-v0.1.2-alpha.4)
#  数据区: /vol1/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4/.dsh-home/.dsh (全新，避免配对)
#  用法:   ./start.sh [start|stop|restart|status]    (默认 start)
#  说明:   start/restart 内部调用 dsh-repair.js 全自动修复
#          （定位 DSH 目录 → 权限修复 → 启动三端口）
# ============================================================

DSH_DIR="/vol1/1000/DeepSeek Harness/dsh-v0.1.2-alpha.4"
DSH_HOME_DIR="$DSH_DIR/.dsh-home/.dsh"
DSH_HOME_PARENT="$DSH_DIR/.dsh-home"
REPAIR_JS="/vol1/1000/DeepSeek Harness/dsh-repair.js"
NODE_BIN="/vol1/@appcenter/nodejs_v24/bin/node"
PID_FILE="/tmp/dsh-repair.pid"
LOG_FILE="/tmp/dsh-repair.log"

PORT_LIST="30800 30801 30802"

# ---------- 工具 ----------
is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ---------- start ----------
cmd_start() {
  if is_running; then
    echo "DSH 已在运行 (PID $(cat "$PID_FILE"))"
    local TOKEN
    TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" | tail -1 | cut -d= -f2)
    if [ -n "$TOKEN" ]; then
      echo "  Token: $TOKEN"
      echo "  局域网访问: http://10.10.10.4:30800/?token=$TOKEN"
    fi
    return 0
  fi
  echo "启动 DSH ..."
  # PATH 前置用户级 pnpm wrapper：pnpm 11 不再读 package.json 的 pnpm 字段，
  # wrapper 自动桥接 JSON->pnpm-workspace.yaml 后再执行官方 pnpm（见 pnpm-bridge.py）
  export PATH="$HOME/.local/bin:$PATH"
  nohup "$NODE_BIN" "$REPAIR_JS" --dsh "$DSH_DIR" --dsh-home "$DSH_HOME_DIR" --home "$DSH_HOME_PARENT" > "$LOG_FILE" 2>&1 &
  echo "后台启动中，日志: $LOG_FILE"
  # 等端口就绪（最多 15 秒）
  for i in $(seq 1 15); do
    sleep 1
    local ready=1
    for p in $PORT_LIST; do
      ss -tln 2>/dev/null | grep -q ":$p " || { ready=0; break; }
    done
    if [ "$ready" = "1" ]; then
      # 等 dsh-repair.js 打印完成摘要（token 稍晚写入日志）
      sleep 3
      echo "DSH 启动完成"
      echo ""
      # 提取 token
      local TOKEN
      TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" | tail -1 | cut -d= -f2)
      if [ -n "$TOKEN" ]; then
        echo "  Token: $TOKEN"
        echo "  首次认证: http://10.10.10.4:30800/?token=$TOKEN"
        echo "  认证后访问: http://10.10.10.4:30800/"
        echo "  容器页面: http://10.10.10.4:30802/"
      else
        tail -12 "$LOG_FILE" | grep -E "✅|认证|访问|容器" || true
      fi
      return 0
    fi
  done
  echo "! 端口未就绪，请查看日志: $LOG_FILE"
}

# ---------- stop ----------
cmd_stop() {
  if ! is_running; then
    echo "DSH 未运行"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  echo "停止 DSH (PID $pid) ..."
  kill "$pid" 2>/dev/null
  # 等主进程退出
  for i in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  # 兜底：清理孤儿 DSH web 进程（cwd 匹配本实例）
  for p in $(pgrep -f "bin.ts web|bin.js web" 2>/dev/null); do
    cwd=$(readlink /proc/$p/cwd 2>/dev/null)
    if [ "$cwd" = "$DSH_DIR" ]; then
      kill -9 "$p" 2>/dev/null
    fi
  done
  rm -f "$PID_FILE"
  # 等端口释放
  for i in $(seq 1 10); do
    local busy=0
    for p in $PORT_LIST; do
      ss -tln 2>/dev/null | grep -q ":$p " && busy=1
    done
    [ "$busy" = "0" ] && break
    sleep 1
  done
  echo "DSH 已停止"
}

# ---------- restart ----------
cmd_restart() {
  cmd_stop
  cmd_start
}

# ---------- status ----------
cmd_status() {
  if is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    echo "DSH 运行中 (PID $pid)"
    local TOKEN
    TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" | tail -1 | cut -d= -f2)
    if [ -n "$TOKEN" ]; then
      echo ""
      echo "  Token: $TOKEN"
      echo "  局域网访问: http://10.10.10.4:30800/?token=$TOKEN"
    fi
  else
    echo "DSH 未运行"
  fi
  echo ""
  echo "端口状态:"
  for p in $PORT_LIST; do
    if ss -tln 2>/dev/null | grep -q ":$p "; then
      echo "  $p  ✅ 监听中"
    else
      echo "  $p  ❌ 未监听"
    fi
  done
  echo ""
  echo "日志: $LOG_FILE"
}

# ---------- main ----------
case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  *)
    echo "用法: $0 [start|stop|restart|status]"
    exit 1
    ;;
esac