#!/usr/bin/env python3
"""
最小 WebSocket 客户端 —— 用于对 DSH 的 /api/remote.mux 发起流式调用。

为什么手写：目标机（群晖）没有 ws / websockets 库，只有标准库。
只实现客户端必需的最小集：握手、掩码帧发送、帧接收（含分片与 ping/pong）。
不依赖第三方库，Python 3.8+ 标准库即可。

协议依据（从 DSH 源码读出）：
  · WebSocket 端点  : /api/remote.mux
  · 打开流          : {"type":"open","streamId":<id>,"endpoint":<名>,"payload":{args:{...}}}
  · 服务端帧        : {"type":"item"|"end"|"error","streamId":<id>,"value"/"error":...}
  · 认证            : 与 HTTP 相同的 cookie（先经 token 换 cookie）
"""
import base64
import hashlib
import json
import os
import socket
import ssl
import struct
from urllib.parse import urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WsClient:
    """极简 WebSocket 客户端（文本帧）。"""

    def __init__(self, url, cookie=None, timeout=30, insecure=True):
        self.url = url
        self.cookie = cookie
        self.timeout = timeout
        self.insecure = insecure
        self.sock = None

    # ---------- 握手 ----------
    def connect(self):
        u = urlparse(self.url)
        host = u.hostname
        port = u.port or (443 if u.scheme == "wss" else 80)
        path = u.path or "/"
        if u.query:
            path += "?" + u.query

        raw = socket.create_connection((host, port), timeout=self.timeout)
        if u.scheme == "wss":
            ctx = ssl.create_default_context()
            if self.insecure:
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            raw = ctx.wrap_socket(raw, server_hostname=host)
        self.sock = raw

        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if self.cookie:
            lines.append(f"Cookie: {self.cookie}")
        req = "\r\n".join(lines) + "\r\n\r\n"
        self.sock.sendall(req.encode())

        # 读响应头
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("WebSocket 握手时连接被关闭")
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        text = head.decode("latin1")
        status_line = text.split("\r\n")[0]
        if "101" not in status_line:
            raise RuntimeError(f"WebSocket 握手失败: {status_line}\n{text[:400]}")

        # 校验 accept
        accept = None
        for line in text.split("\r\n")[1:]:
            if line.lower().startswith("sec-websocket-accept:"):
                accept = line.split(":", 1)[1].strip()
        expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if accept and accept != expected:
            raise RuntimeError("WebSocket accept 校验失败")

        self._buf = rest
        return True

    # ---------- 发送 ----------
    def send_text(self, text):
        data = text.encode("utf-8")
        header = bytearray()
        header.append(0x81)                      # FIN + text
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(header) + masked)

    # ---------- 收帧 ----------
    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("连接已关闭")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv_frame(self):
        """收一帧，返回 (opcode, payload bytes)。自动处理 ping/pong。"""
        while True:
            b1, b2 = self._recv_exact(2)
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if masked else None
            payload = self._recv_exact(length) if length else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == 0x9:                    # ping -> pong（只发控制帧）
                self._send_control(0xA, payload)
                continue
            if opcode == 0xA:                    # pong
                continue
            if opcode == 0x8:                    # close
                raise RuntimeError("服务端关闭了连接")
            return opcode, payload

    def _send_control(self, opcode, payload=b""):
        header = bytearray([0x80 | opcode])
        mask = os.urandom(4)
        header.append(0x80 | len(payload))
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv_text(self):
        opcode, payload = self.recv_frame()
        return payload.decode("utf-8", "replace")

    def close(self):
        try:
            if self.sock:
                self._send_control(0x8, b"\x03\xe8")
                self.sock.close()
        except Exception:
            pass


def open_stream(ws_url, cookie, endpoint, args, max_frames=20, timeout=30, verbose=True):
    """
    打开一个流式 RPC 并收集帧。
    :returns: (frames, error) —— frames 是收到的所有 JSON 帧
    """
    cli = WsClient(ws_url, cookie=cookie, timeout=timeout)
    cli.connect()
    if verbose:
        print("  ✓ WebSocket 已连接")

    sid = "probe-" + os.urandom(6).hex()
    cli.send_text(json.dumps({
        "type": "open",
        "streamId": sid,
        "endpoint": endpoint,
        "payload": {"args": args},
    }, ensure_ascii=False))

    frames = []
    err = None
    try:
        while len(frames) < max_frames:
            text = cli.recv_text()
            try:
                msg = json.loads(text)
            except Exception:
                frames.append({"raw": text[:300]})
                continue
            frames.append(msg)
            if msg.get("type") in ("end", "error"):
                if msg.get("type") == "error":
                    err = msg.get("error")
                break
    except Exception as e:
        err = {"code": "client/exception", "message": str(e)}
    finally:
        cli.close()
    return frames, err


if __name__ == "__main__":
    import sys
    # 冒烟测试：连上并打开 session/follow
    ws = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:30801/api/remote.mux"
    ck = sys.argv[2] if len(sys.argv) > 2 else ""
    sid_ = sys.argv[3] if len(sys.argv) > 3 else ""
    frames, err = open_stream(
        ws, ck, "session/follow",
        {"request": {"address": {"kind": "session", "sessionId": sid_}, "maxMessages": 2}},
        max_frames=5,
    )
    print("  收到帧:", len(frames))
    for f in frames[:3]:
        print("   ", json.dumps(f, ensure_ascii=False)[:300])
    if err:
        print("  错误:", json.dumps(err, ensure_ascii=False)[:300])
