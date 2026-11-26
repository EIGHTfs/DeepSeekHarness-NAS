#!/bin/bash
# entrypoint.sh —— Docker 版的入口：把宿主目录接成工作区，再交给套件自带的 start.sh 起服。
#
# 设计意图（为什么这么做，而不是另写一套启动逻辑）：
#   套件版的 start.sh 已经把「端口探测 → 反代与门户 token → dsh 启动 → 自检 → 残留实例清理」
#   全部做完了，容器里没有任何理由重写一遍。这里只补两件容器特有的事：
#     ① 宿主目录与容器用户的属主对齐（PUID/PGID/UMASK）；
#     ② 按挂载清单为每个宿主目录建 /workspace/<名> 别名，让人有个短入口，
#        同时保留宿主原路径（同路径挂载）以便会话记录里的绝对路径与裸机一致。
#
# 挂载清单（可选，默认 /etc/dsh/workspaces.json）：
#   {"workspaces":[{"name":"projects","path":"/volume1/projects"}, ...]}
#   · path 必须是**宿主目录在容器内的同路径**（即 compose 里 /a/b:/a/b 这样挂），否则别名指向空处；
#   · name 只用于别名，取字母数字与连字符。
#
# 为什么用自带 node 解析 JSON：镜像里没有 python3，而 node 就在 /opt/dsh/bin/node，
#   不额外装包、也不引入第二种运行时。
set -uo pipefail

DSH_ROOT="${DSH_ROOT:-/opt/dsh}"
DATA_ROOT="${PKG_VAR:-/data}"
MANIFEST="${DSH_WORKSPACES_MANIFEST:-/etc/dsh/workspaces.json}"
ALIAS_ROOT="${DSH_WORKSPACE_ALIAS_ROOT:-/workspace}"

log() { echo "[entrypoint] $*"; }

# ── ① 属主对齐：只有以 root 进来且给了 PUID/PGID 时才降权重跑 ────────────────
#   为什么必须降权：容器内以 root 写文件会在宿主留下 root 属主，DSM 上普通用户既改不动也删不掉；
#   而 workspace 里产出的是用户的工程文件，必须与宿主属主一致。
if [ "$(id -u)" = "0" ] && [ -n "${PUID:-}" ] && [ -n "${PGID:-}" ]; then
  log "以 PUID=${PUID} PGID=${PGID} 运行（数据目录 $DATA_ROOT 会 chown 对齐）"
  mkdir -p "$DATA_ROOT"
  chown -R "${PUID}:${PGID}" "$DATA_ROOT" 2>/dev/null || log "⚠ 数据目录 chown 失败（挂载可能是只读或非本地盘）"
  exec setpriv --reuid "$PUID" --regid "$PGID" --clear-groups "$0" "$@"
fi

umask "${UMASK:-0022}"

# ── ② 工作区别名：宿主路径已在容器内同路径挂载，这里只加短入口 ───────────────
mkdir -p "$ALIAS_ROOT" 2>/dev/null || true
if [ -f "$MANIFEST" ] && [ -x "$DSH_ROOT/bin/node" ]; then
  "$DSH_ROOT/bin/node" -e '
    const fs = require("fs");
    const [manifestPath, aliasRoot] = process.argv.slice(1);
    let data;
    try { data = JSON.parse(fs.readFileSync(manifestPath, "utf8")); }
    catch (error) { console.log("BAD " + error.message); process.exit(0); }
    for (const item of (data.workspaces || [])) {
      const name = String(item.name || "").trim();
      const target = String(item.path || "").trim();
      if (!/^[A-Za-z0-9._-]+$/.test(name) || !target) { console.log("SKIP " + (name || "?") + " 名字或路径非法"); continue; }
      let stat = null;
      try { stat = fs.statSync(target); } catch (error) { console.log("MISS " + name + " " + target + "（宿主目录没有挂进容器）"); continue; }
      if (!stat.isDirectory()) { console.log("MISS " + name + " " + target + "（不是目录）"); continue; }
      const alias = require("path").join(aliasRoot, name);
      try { fs.rmSync(alias, { force: true, recursive: false }); } catch (error) {}
      fs.symlinkSync(target, alias);
      console.log("LINK " + name + " " + target);
    }
  ' "$MANIFEST" "$ALIAS_ROOT" 2>/dev/null | while read -r kind rest; do
    case "$kind" in
      LINK) log "工作区别名：$ALIAS_ROOT/${rest%% *} → ${rest#* }" ;;
      MISS) log "⚠ 跳过工作区 ${rest}" ;;
      SKIP) log "⚠ 跳过工作区 ${rest}" ;;
      BAD)  log "⚠ 挂载清单无法解析：${rest}" ;;
    esac
  done
else
  [ -f "$MANIFEST" ] || log "未提供挂载清单（$MANIFEST），只按同路径挂载使用"
fi

# ── ③ HOME 指到工作区根：目录选择器（browse 后端）的初始目录取 homedir() ──────
if [ -z "${HOME_OVERRIDE_DONE:-}" ]; then
  export HOME="${DSH_WORKSPACE_HOME:-$ALIAS_ROOT}"
  export HOME_OVERRIDE_DONE=1
fi
log "HOME=$HOME（目录选择器会从这里开始）"

# ── ④ 交给套件自带的启停脚本；容器停服必须走它，才能留下正常退出状态 ─────────
cd "$DSH_ROOT" || { log "✗ 找不到 $DSH_ROOT"; exit 1; }
./start.sh stop >/dev/null 2>&1 || true      # 上一次容器被强杀时可能残留进程/端口
if ! ./start.sh start; then
  log "✗ start.sh start 失败，下面打印最近日志"
  tail -30 "${DATA_ROOT}/${PKG_VERSION}/DeepSeekHarness-NAS.log" 2>/dev/null \
    || tail -30 "${DATA_ROOT}"/*/DeepSeekHarness-NAS.log 2>/dev/null || true
  ./start.sh stop >/dev/null 2>&1 || true
  exit 1
fi

trap './start.sh stop; exit 0' TERM INT
log "就绪。保持前台运行（容器 stop 会转成 start.sh stop）"
while :; do
  sleep 3600 &
  wait $!
done
