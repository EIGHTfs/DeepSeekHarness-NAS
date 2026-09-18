#!/usr/bin/env python3
"""
follow.py —— 触发 DSH 把已投放的会话迁移到当前格式版本。

用法：
    python3 follow.py <会话id|all> <DSH_HOME> [--port 30801] [--wait 90]

原理（与源码对齐）：
  · DSH 的会话迁移发生在「会话被打开跟随」时，而不是扫描时。
    实测：HTTP 的 session/page 只做冷读，读完不产生 session.v3.jsonl.zstd；
    流式的 session/follow 一走，lock 与 v3 立刻落盘。
  · follow 是流式 Remote 方法，必须走 WebSocket：/api/remote.mux
    帧格式：{"type":"open","streamId":<id>,"endpoint":"session/follow","payload":{"args":{...}}}
  · 认证：先 HTTP 用 token 换 cookie（token 在启动输出 "dsh web: http://.../?token=..." 里），
    再把同一 cookie 带进 WebSocket 握手。cookie 名形如 dsh-auth-<随机串>。

为什么用 Python：目标机（群晖）无 node_modules/ws、无 websockets 库，标准库最稳。
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wsclient import open_stream  # noqa: E402


def sh(cmd):
    """跑一条 shell 命令，返回 stdout（失败返回空串）。"""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return r.stdout or ""
    except Exception:
        return ""


def find_token(home):
    """
    找到当前实例的 web token。
    启动输出形如：dsh web: http://127.0.0.1:30801/?token=XXXX
    它被写到实例根目录（home 的上一级）的 <实例名>.log 里。
    """
    cands = []
    root = os.path.dirname(os.path.abspath(home))          # <实例根>
    if os.path.isdir(root):
        for f in os.listdir(root):
            if f.endswith(".log"):
                cands.append(os.path.join(root, f))
    # 兜底：dsh-proxy.log（历史 token）
    cands.append(os.path.join(root, "dsh-proxy.log"))

    newest = None
    for p in cands:
        try:
            t = open(p, "rb").read().decode("utf8", "replace")
        except Exception:
            continue
        toks = re.findall(r"token=([A-Za-z0-9_-]{20,})", t)
        if not toks:
            continue
        # 主日志（非 proxy）优先，且取最后一个
        if "proxy" not in os.path.basename(p):
            return toks[-1], p
        newest = newest or (toks[-1], p)
    return (newest or (None, ""))


def exchange_cookie(port, token, host="127.0.0.1"):
    """用 token 换认证 cookie。返回 'name=value' 或 None。"""
    out = sh(f'curl -s -m 8 -D - -o /dev/null "http://{host}:{port}/?token={token}" 2>/dev/null')
    for line in (out or "").splitlines():
        if line.lower().startswith("set-cookie:"):  # dsh-skip-residue 仅解析响应头，非构造 Cookie，无 Secure/HttpOnly 可加
            ck = line.split(":", 1)[1].strip().split(";")[0].strip()
            if ck:
                return ck
    return None


def rpc(port, cookie, endpoint, args, host="127.0.0.1", timeout=30):
    """普通（非流式）RPC 调用，走 POST /api/<endpoint>。"""
    body = json.dumps({
        "type": "client-request", "rpcId": "cli-1",
        "method": endpoint, "payload": {"args": args},
    }, ensure_ascii=False)
    out = sh(
        f"curl -s -m {timeout} -b '{cookie}' -X POST 'http://{host}:{port}/api/{endpoint}' "
        f"-H 'content-type: application/json' --data-binary @- <<'JSONEOF'\n{body}\nJSONEOF"
    )
    try:
        j = json.loads(out)
        return j.get("result", {})
    except Exception:
        return {"ok": False, "error": {"message": f"响应无法解析: {out[:200]}"}}


def list_sessions(port, cookie, host="127.0.0.1"):
    """列会话（session/list），返回 items。"""
    r = rpc(port, cookie, "session/list", {"_request": {}}, host=host)
    if not r.get("ok"):
        return None, r.get("error", {}).get("message", "未知错误")
    return (r.get("value") or {}).get("items", []), None


def follow(port, cookie, session_id, host="127.0.0.1", wait=60, verbose=True):
    """
    对某会话发起 session/follow —— 这是触发迁移的关键动作。
    返回 (ok, header_version, error)
    """
    ws = f"ws://{host}:{port}/api/remote.mux"
    args = {
        "request": {
            "address": {"kind": "session", "sessionId": session_id},
            "maxMessages": 1,
        }
    }
    frames, err = open_stream(ws, cookie, "session/follow", args,
                              max_frames=3, timeout=wait, verbose=verbose)
    ver = None
    for f in frames:
        v = f.get("value")
        if isinstance(v, dict) and v.get("type") == "snapshot":
            ver = (v.get("header") or {}).get("version")
            break
    # follow 是长连接流，收到 snapshot 即算成功（服务端随后关闭属正常）
    ok = ver is not None
    return ok, ver, err


def wait_for_artifacts(home, session_id, timeout=120):
    """等 session.v3.jsonl.zstd 落盘。返回产物路径或 None。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for dirpath, dirnames, filenames in os.walk(os.path.join(home, "sessions")):
            if os.path.basename(dirpath) == session_id:
                p = os.path.join(dirpath, "session.v3.jsonl.zstd")
                if os.path.exists(p) and os.path.getsize(p) > 0:
                    return p
        time.sleep(2)
    return None


def main():
    ap = argparse.ArgumentParser(description="触发 DSH 会话迁移（WebSocket session/follow）")
    ap.add_argument("target", help="会话 id（或 all 表示全部未迁移会话）")
    ap.add_argument("home", help="DSH_HOME（.dsh 目录）")
    ap.add_argument("--port", type=int, default=30801)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wait", type=int, default=90, help="等待迁移产物的秒数")
    args = ap.parse_args()

    home = os.path.abspath(args.home)
    token, src = find_token(home)
    if not token:
        print("  ✗ 未找到 web token。请确认 DSH 正在运行，且实例根目录有启动日志。")
        return 1
    print(f"  token 来源: {src}")

    cookie = exchange_cookie(args.port, token, args.host)
    if not cookie:
        print("  ✗ token 换 cookie 失败（token 可能已过期：DSH 重启会换新 token）")
        return 1
    print(f"  cookie: {cookie[:36]}...")

    sessions, err = list_sessions(args.port, cookie, args.host)
    if sessions is None:
        print(f"  ✗ session/list 失败: {err}")
        return 1
    print(f"  在线会话: {len(sessions)} 个")

    # 解析目标
    if args.target == "all":
        targets = []
        for it in sessions:
            sid = it.get("sessionId")
            found = None
            for dirpath, dirnames, filenames in os.walk(os.path.join(home, "sessions")):
                if os.path.basename(dirpath) == sid:
                    found = dirpath
                    break
            if not found:
                continue
            has_v3 = os.path.exists(os.path.join(found, "session.v3.jsonl.zstd"))
            if not has_v3:
                targets.append(sid)
        if not targets:
            print("  没有待迁移的会话（都已生成 v3）")
            return 0
    else:
        targets = [args.target]

    print(f"  待迁移: {len(targets)} 个")
    rc = 0
    for sid in targets:
        print(f"\n── {sid}")
        ok, ver, e = follow(args.port, cookie, sid, args.host, args.wait)
        if not ok:
            print(f"  ✗ follow 未取到 snapshot: {json.dumps(e, ensure_ascii=False) if e else '无响应'}")
            rc = 1
            continue
        print(f"  ✓ follow 成功，服务端 header.version = v{ver}")

        p = wait_for_artifacts(home, sid, args.wait)
        if p:
            print(f"  ✓ 迁移产物已落盘: {os.path.relpath(p, home)}  ({os.path.getsize(p)} 字节)")
        else:
            print(f"  ⚠ {args.wait}s 内未见 v3 落盘（可能仍在写，或该会话无需迁移）")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
