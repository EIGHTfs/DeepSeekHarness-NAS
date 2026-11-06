#!/usr/bin/env bash
# connect-local.sh —— 建立到 NAS 的 SSH 本地转发，用于「浏览器登录（OAuth）」。
#
# 为什么需要它：DeepSeekRuntime 的浏览器登录只接受回环来源
#   （http://localhost:<端口> / http://127.0.0.1:<端口> / http://[::1]:<端口>），
#   直接访问 http://<NAS-IP>:<反代端口> 点登录会被拒（平台侧同样校验，改产物也无效）。
#   把端口转发到本机回环后，地址栏是 127.0.0.1，登录即可正常走完授权。
#   日常使用不需要登录，用 API Key 也可以；本脚本只服务「要登录」这一种场景。
#
# 转发两个端口：
#   反代端口（从目标机读取，不写死）—— 门户本体，登录入口在这一层
#   容器页端口（从目标机读取）—— 可选；容器页是 iframe 外壳，iframe 会指向 127.0.0.1 的反代端口
#
# 用法:
#   ./connect-local.sh <NAS地址> [SSH用户] [SSH端口]
#   LOCAL_PORT=31800 ./connect-local.sh <NAS-IP> root 22        # 本机默认端口被占用时换端口
#
# 参数（均可省略，除 NAS 地址）:
#   1. NAS地址   NAS 的局域网地址或域名
#   2. SSH用户   SSH 登录用户，默认 root
#   3. SSH端口   SSH 端口，默认 22
# 环境变量:
#   LOCAL_PORT      本机用于建隧道并打开浏览器的端口，缺省 = 远端反代端口
#   REMOTE_PROXY    远端反代端口，缺省从目标机读取
#   REMOTE_CONTAINER 远端容器页端口，缺省从目标机读取
#   NO_BROWSER=1    只建隧道、不自动打开浏览器
#
# 退出：Ctrl-C 结束隧道。

set -u

NAS_HOST="${1:-}"
SSH_USER="${2:-root}"
SSH_PORT="${3:-22}"
LOCAL_PORT="${LOCAL_PORT:-}"          # 空 = 用远端读到的反代端口（本机被占用时可用 LOCAL_PORT 覆盖）
REMOTE_PROXY="${REMOTE_PROXY:-}"      # 空 = 从目标机读取
REMOTE_CONTAINER="${REMOTE_CONTAINER:-}"  # 空 = 从目标机读取

if [ -z "$NAS_HOST" ]; then
  echo "用法: $0 <NAS地址> [SSH用户] [SSH端口]" >&2
  echo "  例: $0 <NAS-IP> root 22      （本机端口被占时：LOCAL_PORT=31800 $0 <NAS-IP>）" >&2
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "✗ 本机没有 ssh 客户端，请先安装 OpenSSH" >&2
  exit 1
fi

# 远端端口发现：从目标机已装套件的 ports 文件读取，避免把端口写死在本脚本里。
#   端口文件由打包与安装向导生成，位置随版本目录变化 → 这里按 /var/packages/*/var/*/ports 扫描，
#   取第一个含 PROXY_PORT 的文件。读不到就直接报错（不猜默认值，避免连到错误端口）。
read_remote_ports() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$NAS_HOST" '
    for f in /var/packages/*/var/*/ports /var/packages/*/target/var/ports; do
      [ -f "$f" ] || continue
      if grep -q "^PROXY_PORT=" "$f" 2>/dev/null; then
        grep -E "^(PROXY_PORT|CONTAINER_PORT)=" "$f"
        exit 0
      fi
    done
    exit 1
  ' 2>/dev/null
}

if [ -z "$REMOTE_PROXY" ] || [ -z "$REMOTE_CONTAINER" ]; then
  echo "→ 从 $SSH_USER@$NAS_HOST 读取端口…"
  if ! _ports="$(read_remote_ports)" || [ -z "$_ports" ]; then
    echo "✗ 读不到目标机端口：请确认套件已安装，或用 REMOTE_PROXY/REMOTE_CONTAINER 显式指定" >&2
    echo "  例：REMOTE_PROXY=<反代端口> REMOTE_CONTAINER=<容器页端口> $0 $NAS_HOST $SSH_USER $SSH_PORT" >&2
    exit 1
  fi
  REMOTE_PROXY="${REMOTE_PROXY:-$(printf '%s\n' "$_ports" | sed -n 's/^PROXY_PORT=//p' | head -1)}"
  REMOTE_CONTAINER="${REMOTE_CONTAINER:-$(printf '%s\n' "$_ports" | sed -n 's/^CONTAINER_PORT=//p' | head -1)}"
  [ -n "$REMOTE_CONTAINER" ] || REMOTE_CONTAINER="$REMOTE_PROXY"
  echo "  反代端口=$REMOTE_PROXY 容器页端口=$REMOTE_CONTAINER"
fi

# 本机端口缺省 = 远端反代端口（回环 + 同端口号，登录校验只看回环与显式端口）
[ -n "$LOCAL_PORT" ] || LOCAL_PORT="$REMOTE_PROXY"

# 本机端口占用检查：被占用时 SSH 会静默失败（不加 ExitOnForwardFailure 的话），
# 提前判一次并给出替代命令，比让用户对着"连不上"猜原因省事。
port_busy() {
  # /dev/tcp 是 bash 内建（ash/dash 没有）→ 本脚本用 bash shebang ✓；再备一个 nc 兜底
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then exec 3>&-; return 0; fi
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0; fi
  return 1
}

if port_busy "$LOCAL_PORT"; then
  echo "✗ 本机 $LOCAL_PORT 已被占用（另一个实例或其它程序）" >&2
  echo "  → 换端口重试：LOCAL_PORT=31800 $0 $NAS_HOST $SSH_USER $SSH_PORT" >&2
  exit 1
fi

SSH_OPTS="-N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes"

echo "→ 建立隧道：127.0.0.1:$LOCAL_PORT → $NAS_HOST:$REMOTE_PROXY（经 $SSH_USER@$NAS_HOST:$SSH_PORT）"
# shellcheck disable=SC2086
ssh $SSH_OPTS \
  -p "$SSH_PORT" \
  -L "$LOCAL_PORT:127.0.0.1:$REMOTE_PROXY" \
  -L "$((${LOCAL_PORT} + 2)):127.0.0.1:$REMOTE_CONTAINER" \
  "$SSH_USER@$NAS_HOST" &
SSH_PID=$!

cleanup() {
  if kill -0 "$SSH_PID" 2>/dev/null; then
    kill "$SSH_PID" 2>/dev/null
    wait "$SSH_PID" 2>/dev/null
  fi
  echo "已断开隧道"
}
trap cleanup EXIT INT TERM

# 等端口就绪（最多 ~20 秒）；不依赖 curl，能连上就算通。
i=0
while [ "$i" -lt 40 ]; do
  if port_busy "$LOCAL_PORT"; then break; fi
  if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "✗ SSH 隧道没能建立（连接被拒或需要密码/密钥）。" >&2
    echo "  排错：先手动执行 ssh -p $SSH_PORT $SSH_USER@$NAS_HOST 确认能登录成功。" >&2
    exit 1
  fi
  sleep 0.5
  i=$((i + 1))
done

if ! port_busy "$LOCAL_PORT"; then
  echo "✗ 等待超时：$LOCAL_PORT 没有就绪" >&2
  exit 1
fi

URL="http://127.0.0.1:$LOCAL_PORT/"
echo "✓ 隧道就绪：$URL（容器页：http://127.0.0.1:$((LOCAL_PORT + 2))/）"
echo "  登录完成后不要关掉本窗口；按 Ctrl-C 结束隧道。"

if [ "${NO_BROWSER:-0}" != "1" ]; then
  # 打开浏览器：按平台顺序尝试，找不到就只打印地址（不报错，用户自己复制也可）
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1 &
  elif command -v sensible-browser >/dev/null 2>&1; then sensible-browser "$URL" >/dev/null 2>&1 &
  else echo "  （未找到可用的浏览器启动命令，请手动打开上面的地址）"; fi
fi

wait "$SSH_PID"
