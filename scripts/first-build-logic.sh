#!/bin/bash
# ============================================================
#  首启构建逻辑（从 start.sh.example 抽离留档）
#  抽出时间: 2026-09-13
#  背景: 打包唯一模式 = 完整预构建包（-dist），已含 node_modules 与
#        构建产物，装完即用、免首启构建。本脚本仅留档参考。
#  依赖上下文变量（由 start.sh 定义后调用）:
#        DSH_DIR / DSH_HOME_PARENT / NODE_BIN / PKG_VERSION / APP_NAME
#  用法: 若未来需要「精简包首启构建」，把下方 ensure_built 函数体
#        复制回 start.sh 并在启动流程中调用 ensure_built 即可。
# ============================================================

# ---------- 精简包首启构建 ----------
#  精简包只含源码（无 node_modules / 无构建产物），首次启动需 install + build。
#  完整包（预构建整包）已含 node_modules 与产物，本函数直接跳过。
#  构建日志: $DSH_HOME_PARENT/first-build.log
ensure_built() {
  # 已构建（有 CLI 产物）→ 直接返回
  [ -f "$DSH_DIR/apps/cli/lib/bin.js" ] && return 0

  # 无源码（连 package.json 都没有）→ 不是精简包场景，交给 detect_entry 报错
  [ -f "$DSH_DIR/package.json" ] || return 0

  local BLOG="$DSH_HOME_PARENT/first-build.log"
  mkdir -p "$DSH_HOME_PARENT" 2>/dev/null || true
  echo "[精简包] 首次启动：需安装依赖并构建（约 10-30 分钟，日志 $BLOG）" >&2

  # ---------- 构建进度占位页（监听 PROXY_PORT，构建完成自动退出）----------
  # 精简包首启构建 10-30 分钟，期间 30800 无监听 → DSM 门户打开=连接失败。
  # 方案 A（用户确认）：构建前用极简 python 占位进程绑定反代端口，
  #   标签页显示 first-build.log 尾部 + 阶段 + 耗时，每 3 秒自动刷新；
  #   构建完成（apps/cli/lib/bin.js 出现）→ 等 2 秒退出 → REPAIR_CODE 反代接管
  #   （REPAIR_CODE 端口等待循环给足 5 秒交接窗口）。
  # 注意：此段只在「确实需要构建」时执行（上方两个 guard 已保证）。
  PH_PORT="${DSH_PROXY_PORT:-__PROXY_PORT__}"
  PH_PY="$DSH_HOME_PARENT/.build-placeholder.py"
  PH_READY="$DSH_DIR/apps/cli/lib/bin.js"
  PH_PID="$DSH_HOME_PARENT/.build-placeholder.pid"
  if command -v python3 >/dev/null 2>&1; then
    cat > "$PH_PY" <<'PH_EOF'
#!/usr/bin/env python3
import http.server, os, sys, time, threading
PORT = int(sys.argv[1]); BLOG = sys.argv[2]; READY = sys.argv[3]
APP = sys.argv[4] if len(sys.argv) > 4 else 'DeepSeekHarness-NAS'
START = time.time()
def tail(path, n=40):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            return ''.join(f.readlines()[-n:])
    except OSError:
        return '（日志尚未生成，请稍候…）'
def elapsed():
    t = int(time.time() - START); h, r = divmod(t, 3600); m, s = divmod(r, 60)
    return '%d:%02d:%02d' % (h, m, s)
def stage():
    try:
        txt = open(BLOG, 'r', encoding='utf-8', errors='replace').read()
    except OSError:
        return 'prep', '⏳ 准备中…'
    if 'pnpm build' in txt: return 'build', '📦 构建中 (pnpm build)'
    if 'pnpm install' in txt: return 'install', '📥 安装依赖 (pnpm install)'
    if 'pnpm-bridge' in txt: return 'prep', '🔧 配置 pnpm 桥接'
    return 'prep', '⏳ 准备中…'
def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        key, stxt = stage()
        html = ('<!DOCTYPE html>\n<html lang="zh-CN"><head><meta charset="utf-8">\n'
                '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
                '<meta http-equiv="refresh" content="3">\n'
                '<title>DSH 首启构建中 - {app}</title>\n'
                '<style>\n'
                '*{{margin:0;padding:0;box-sizing:border-box}}\n'
                'body{{background:#1e1e1e;color:#d4d4d4;font-family:Menlo,Consolas,monospace;padding:24px;min-height:100vh}}\n'
                'h1{{font-size:20px;color:#569cd6;margin-bottom:6px}}\n'
                '.meta{{color:#9cdcfe;font-size:13px;margin-bottom:18px}}\n'
                '.badge{{display:inline-block;padding:4px 12px;border-radius:12px;font-size:13px;margin-bottom:14px}}\n'
                '.badge.install{{background:#1b3a1b;color:#6fdd8b;border:1px solid #2e7d32}}\n'
                '.badge.build{{background:#1b2a3a;color:#64b5f6;border:1px solid #1565c0}}\n'
                '.badge.prep{{background:#3a2a1b;color:#ffb74d;border:1px solid #ef6c00}}\n'
                'pre{{background:#252526;border:1px solid #3a3a3a;border-radius:8px;padding:16px;\n'
                '    font-size:12px;line-height:1.6;overflow:auto;max-height:65vh;white-space:pre-wrap;word-break:break-all}}\n'
                '.footer{{margin-top:14px;font-size:12px;color:#888}}\n'
                '</style></head><body>\n'
                '<h1>🛠 {app} 首次构建</h1>\n'
                '<div class="meta">已完成：{elp} &nbsp;|&nbsp; 构建日志实时刷新（每 3 秒）</div>\n'
                '<div class="badge {key}">{stxt}</div>\n'
                '<pre>{log}</pre>\n'
                '<div class="footer">构建完成后本页自动消失，进入 DSH 管理界面。首次构建约 10-30 分钟，请勿刷新关闭。</div>\n'
                '</body></html>').format(app=APP, elp=elapsed(), key=key, stxt=stxt, log=esc(tail(BLOG)))
        body = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
def watcher():
    while True:
        if os.path.exists(READY):
            time.sleep(2)
            os._exit(0)
        time.sleep(2)
threading.Thread(target=watcher, daemon=True).start()
http.server.ThreadingHTTPServer.allow_reuse_address = True
srv = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), H)
srv.serve_forever()
PH_EOF
    chmod +x "$PH_PY"
    nohup python3 "$PH_PY" "$PH_PORT" "$BLOG" "$PH_READY" "${APP_NAME:-DeepSeekHarness-NAS}"       >/dev/null 2>&1 &
    echo $! > "$PH_PID"
    echo "[精简包] 构建进度占位已启动: http://<NAS-IP>:${PH_PORT}/ （构建完成自动移交反代）" >&2
  else
    echo "[精简包] 未找到 python3，跳过构建进度占位页（构建期间 ${PH_PORT} 不可达）" >&2
  fi

  # 定位 pnpm：优先包内自带（$DSH_DIR/pnpm，随精简包分发，10/11 通用），
  # 其次系统 pnpm；两者都无则报错（内嵌 node 是精简版，无 npm/corepack，不能 npx）
  local PNPM_CMD=""
  if [ -f "$DSH_DIR/pnpm/bin/pnpm.mjs" ]; then
    PNPM_CMD="$NODE_BIN $DSH_DIR/pnpm/bin/pnpm.mjs"
  else
    for c in "$DSH_DIR/bin/pnpm" "$HOME/.local/bin/pnpm" "/usr/local/bin/pnpm" "/usr/bin/pnpm"; do
      [ -x "$c" ] && { PNPM_CMD="$c"; break; }
    done
  fi
  if [ -z "$PNPM_CMD" ]; then
    echo "[精简包] 未找到 pnpm（包内 $DSH_DIR/pnpm 与系统 pnpm 均缺失），无法首启构建" >&2
    echo "=== 精简包首启构建中止 $(date '+%F %T')：未找到 pnpm ===" >>"$BLOG"
    return 0
  fi

  # pnpm/ npm shim：构建脚本内部会调 `pnpm run xxx`（package.json scripts 链式调用），
  # 必须让 PATH 里存在名为 pnpm 的可执行文件（内嵌 node 无 npm，故自建 shim）
  local SHIM_DIR="$DSH_HOME_PARENT/.build-bin"
  mkdir -p "$SHIM_DIR" 2>/dev/null || true
  if [ -f "$DSH_DIR/pnpm/bin/pnpm.mjs" ]; then
    cat > "$SHIM_DIR/pnpm" <<SHIMEOF
#!/bin/sh
exec "$NODE_BIN" "$DSH_DIR/pnpm/bin/pnpm.mjs" "\$@"
SHIMEOF
    chmod +x "$SHIM_DIR/pnpm"
    [ -f "$DSH_DIR/pnpm/bin/pnpx.mjs" ] && {
      cat > "$SHIM_DIR/pnpx" <<SHIMEOF
#!/bin/sh
exec "$NODE_BIN" "$DSH_DIR/pnpm/bin/pnpx.mjs" "\$@"
SHIMEOF
      chmod +x "$SHIM_DIR/pnpx"
    }
    [ -f "$DSH_DIR/pnpm/bin/pnpm.cjs" ] && {
      cat > "$SHIM_DIR/npx" <<SHIMEOF
#!/bin/sh
exec "$NODE_BIN" "$DSH_DIR/pnpm/bin/pnpx.mjs" "\$@"
SHIMEOF
      chmod +x "$SHIM_DIR/npx"
    }
  fi
  PNPM_SHIM_PATH="$SHIM_DIR:$(dirname "$NODE_BIN")"

  {
    echo "=== 精简包首启构建 $(date '+%F %T') ==="
    echo "DSH_DIR=$DSH_DIR"
    echo "NODE=$NODE_BIN  PNPM=$PNPM_CMD"
    echo "PYTHON=$(command -v python3 2>/dev/null || echo '缺失')"

    # pnpm 11 配置桥接：package.json 的 pnpm 字段 → pnpm-workspace.yaml
    if [ -f "$DSH_DIR/pnpm/pnpm-bridge.py" ] && command -v python3 >/dev/null 2>&1; then
      echo "--- pnpm-bridge（pnpm11 配置桥接） ---"
      ( cd "$DSH_DIR" && python3 "$DSH_DIR/pnpm/pnpm-bridge.py" --dir "." 2>&1 | tail -5 )
    fi

    if [ ! -d "$DSH_DIR/node_modules" ]; then
      echo "--- pnpm install（需联网下载依赖） ---"
      ( cd "$DSH_DIR" && \
        PATH="$PNPM_SHIM_PATH:$PATH" \
        HOME="$DSH_HOME_PARENT" \
        XDG_DATA_HOME="$DSH_HOME_PARENT/.local/share" \
        XDG_CACHE_HOME="$DSH_HOME_PARENT/.cache" \
        PNPM_HOME="$DSH_HOME_PARENT/.pnpm" \
        PNPM_STORE_DIR="${PNPM_STORE_DIR:-$DSH_HOME_PARENT/.pnpm-store}" \
        $PNPM_CMD install 2>&1 | tail -25 )
    else
      echo "--- node_modules 已存在，跳过 install ---"
    fi

    echo "--- pnpm build ---"
    # NAS 无 git：必须显式给 DSH_CLIENT_COMMIT_HASH，否则构建脚本调 git rev-parse 失败
    # （client-build-environment.ts 优先读该变量；缺省用版本号派生稳定值）
    local COMMIT_HASH
    COMMIT_HASH="$(echo -n "DeepSeekHarness-NAS-${PKG_VERSION:-0.0.0}" | md5sum | cut -c1-7)"
    ( cd "$DSH_DIR" && \
      PATH="$PNPM_SHIM_PATH:$PATH" \
      HOME="$DSH_HOME_PARENT" \
      XDG_DATA_HOME="$DSH_HOME_PARENT/.local/share" \
      XDG_CACHE_HOME="$DSH_HOME_PARENT/.cache" \
      PNPM_HOME="$DSH_HOME_PARENT/.pnpm" \
      PNPM_STORE_DIR="${PNPM_STORE_DIR:-$DSH_HOME_PARENT/.pnpm-store}" \
      DSH_CLIENT_VERSION="${PKG_VERSION:-}" \
      DSH_CLIENT_COMMIT_HASH="$COMMIT_HASH" \
      DSH_CLIENT_TITLE="DeepSeekHarness-NAS" \
      DSH_SLIM_SKIP_NATIVE=1 \
      $PNPM_CMD build 2>&1 | tail -30 )
    echo "=== 首启构建结束 $(date '+%F %T') ==="
  } >>"$BLOG" 2>&1 || true

  if [ -f "$DSH_DIR/apps/cli/lib/bin.js" ]; then
    echo "[精简包] 首启构建完成 ✓" >&2
  else
    echo "[精简包] 首启构建未产出 CLI 入口，详见 $BLOG" >&2
  fi
}

# 原调用点（start.sh.example 第 332 行）:
# ensure_built
# 2026-09-13 起不再调用：完整预构建包免首启构建。
