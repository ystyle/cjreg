#!/usr/bin/env python3
"""基准测试用的「假上游」（stub upstream）。

为什么需要它：cjreg 的代理回源是性能对比的一半（本地命中 vs 回源），但把压测打到真实中心仓
既受频率限制、又不安全，且网络抖动会污染数据。桩服务把回源变成**本地、可控、可复现**：

  - 可控延迟：环境变量 STUB_DELAY_MS（默认 0），用来把"上游慢"这个变量固定下来；
  - 确定性制品：内容由 org::name::version 派生，sha256 稳定，便于校验与复现；
  - **请求计数**：/__stats 返回回源次数 —— 「本地命中」不能只看延迟变小，
    还要能证明**根本没有回源**，计数是硬证据。

实现的端点（与 cjreg 的 buildIndexURL / buildPackageURL 对齐）：
  GET /index/<前2>/<次2>/<包名>?organization=<org>   → NDJSON 索引（一行一个版本）
  GET /pkg/<包名>/<版本>?organization=<org>          → 制品字节
  GET /__stats                                       → {"index": n, "pkg": m}
  POST /__reset                                      → 计数清零

用法：
  python3 scripts/bench-stub-upstream.py --port 18081 --packages bench-a,bench-b --versions 1.0.0
"""

import argparse
import hashlib
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
COUNTS = {"index": 0, "pkg": 0}
CHUNKED = os.environ.get("STUB_CHUNKED", "") != ""
CONFIG = {
    "delay_ms": 0,
    "artifact_bytes": 64 * 1024,
    "packages": {},
}


def artifact(org, name, version):
    """确定性制品：同一 (org,name,version) 永远得到同样字节与同样 sha256。"""
    seed = ("%s::%s::%s" % (org, name, version)).encode()
    block = hashlib.sha256(seed).digest()
    size = CONFIG["artifact_bytes"]
    return (block * (size // len(block) + 1))[:size]


def index_ndjson(org, name):
    versions = CONFIG["packages"].get(name, [])
    lines = []
    for v in versions:
        data = artifact(org, name, v)
        lines.append(json.dumps({
            "name": name,
            "version": v,
            "sha256sum": hashlib.sha256(data).hexdigest(),
            "deps": [],
        }, ensure_ascii=False))
    return "\n".join(lines) + ("\n" if lines else "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if CHUNKED:
            # 不报 Content-Length：走 Transfer-Encoding: chunked
            # （用来验证客户端在这种响应下是否按块读取，而不是先整包收下来）
            import math
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            step = 64 * 1024
            for off in range(0, len(body), step):
                piece = body[off:off + step]
                self.wfile.write(b"%x\r\n" % len(piece) + piece + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _maybe_delay(self):
        d = CONFIG["delay_ms"]
        if d > 0:
            time.sleep(d / 1000.0)

    def do_GET(self):
        u = urlparse(self.path)
        org = (parse_qs(u.query).get("organization") or [""])[0]

        if u.path == "/__stats":
            with LOCK:
                self._send(200, json.dumps(dict(COUNTS)), "application/json")
            return

        if u.path.startswith("/index/"):
            name = u.path.rstrip("/").rsplit("/", 1)[-1]
            with LOCK:
                COUNTS["index"] += 1
            self._maybe_delay()
            if name not in CONFIG["packages"]:
                self._send(404, "not found")
                return
            self._send(200, index_ndjson(org, name))
            return

        if u.path.startswith("/pkg/"):
            parts = u.path.split("/")
            if len(parts) < 4:
                self._send(400, "bad path")
                return
            name, version = parts[2], parts[3]
            with LOCK:
                COUNTS["pkg"] += 1
            self._maybe_delay()
            if version not in CONFIG["packages"].get(name, []):
                self._send(404, "not found")
                return
            self._send(200, artifact(org, name, version), "application/octet-stream")
            return

        self._send(404, "not found")

    def do_POST(self):
        if urlparse(self.path).path == "/__reset":
            with LOCK:
                COUNTS["index"] = 0
                COUNTS["pkg"] = 0
            self._send(200, "{\"status\":\"ok\"}", "application/json")
            return
        self._send(404, "not found")

    def log_message(self, *args):
        pass  # 压测期间静音，避免日志本身成为瓶颈


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--packages", default="bench-alpha,bench-beta,bench-gamma",
                    help="预置包名，逗号分隔")
    ap.add_argument("--versions", default="1.0.0,1.0.1",
                    help="每个包预置的版本，逗号分隔")
    ap.add_argument("--artifact-bytes", type=int,
                    default=int(os.environ.get("STUB_ARTIFACT_BYTES", 64 * 1024)))
    args = ap.parse_args()

    CONFIG["delay_ms"] = int(os.environ.get("STUB_DELAY_MS", "0"))
    CONFIG["artifact_bytes"] = args.artifact_bytes
    versions = [v.strip() for v in args.versions.split(",") if v.strip()]
    for p in [p.strip() for p in args.packages.split(",") if p.strip()]:
        CONFIG["packages"][p] = list(versions)

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("[stub] listening on 127.0.0.1:%d delay=%dms artifact=%dB packages=%s"
          % (args.port, CONFIG["delay_ms"], CONFIG["artifact_bytes"],
             ",".join(sorted(CONFIG["packages"]))), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
