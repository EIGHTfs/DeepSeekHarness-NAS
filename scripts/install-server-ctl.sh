#!/usr/bin/env bash
# 8765 安装工具服务端启停脚本
# 用法：./install-server-ctl.sh [start|stop|restart|status]   默认 restart
set -uo pipefail
cd "$(dirname "$0")"
PID_FILE="/tmp/dsh-install-server.pid"
LOG_FILE="server-install.log"
PY_BIN="${PYTHON_BIN:-/usr/bin/python3}"

find_pid() { [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null || echo ""; }
is_running() { local p="$(find_pid)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

status_cmd() {
  local p="$(find_pid)"
  if is_running; then echo "✅ 安装工具服务运行中 (PID $p)"; return 0; fi
  [ -n "$p" ] && rm -f "$PID_FILE"
  echo "⏹ 安装工具服务未运行"; return 1
}

start_cmd() {
  if is_running; then echo "已在运行 (PID $(find_pid))"; return 0; fi
  if command -v setsid >/dev/null 2>&1; then
    setsid "$PY_BIN" install-server.py >>"$LOG_FILE" 2>&1 &
  else
    nohup "$PY_BIN" install-server.py >>"$LOG_FILE" 2>&1 &
  fi
  echo $! > "$PID_FILE"
  sleep 1
  if is_running; then
    echo "✅ 安装工具服务已启动 (PID $(find_pid))，日志 $LOG_FILE"
  else
    echo "❌ 启动失败，看日志 $LOG_FILE"; tail -5 "$LOG_FILE" 2>/dev/null
  fi
}

stop_cmd() {
  if ! is_running; then echo "未运行，无需停止"; rm -f "$PID_FILE"; return 0; fi
  local p="$(find_pid)"
  echo "⏹ 停止安装工具服务 (PID $p)..."
  kill "$p" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  rm -f "$PID_FILE"
  echo "✅ 已停止"
}

ACTION="${1:-restart}"
case "$ACTION" in
  start)   start_cmd ;;
  stop)    stop_cmd ;;
  status)  status_cmd; exit $? ;;
  restart) if is_running; then stop_cmd; fi; start_cmd ;;
  *) echo "用法: ./install-server-ctl.sh [start|stop|restart|status]"; exit 1 ;;
esac