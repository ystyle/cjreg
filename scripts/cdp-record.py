#!/usr/bin/env python3
"""CDP 无损录制：Page.startScreencast(format=png) 收帧 → ffmpeg 合成 mp4。

为什么不用 agent-browser record：它走 CDP screencast 的 **JPEG** 通道（质量固定），
页面里 1px 的浅色边框（Element Plus 的输入框/表格线）会在压缩里被抹掉 ——
录出来"看不到框"。改成 PNG 帧就无损了，**不需要给页面注入任何样式**。

用法：
  cdp-record.py rec <输出目录> [--port 9222]      # 录制；SIGINT/SIGTERM 结束
  cdp-record.py mp4 <帧目录> <输出.mp4> [--fps 30] # 按真实帧间隔合成

rec 会在帧目录写 frame-%05d.png 与 frames.tsv（帧号\t相对毫秒），
mp4 用 frames.tsv 的真实间隔生成 concat 列表，所以节奏与录制时一致
（CDP screencast 只在画面变化时发帧，帧间隔本来就不均匀）。
"""

import base64
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request

try:
    import websocket  # websocket-client
except ImportError:  # pragma: no cover
    sys.exit("缺少 websocket-client（pip install websocket-client）")

RUNNING = True


def _stop(signum, frame):
    global RUNNING
    RUNNING = False


def page_ws_url(port: int) -> str:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
        targets = json.load(r)
    for t in targets:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    sys.exit("找不到 page 类型的 CDP target")


def cmd_rec(out_dir: str, port: int, interval_ms: int = 100,
            width: int = 1920, height: int = 1080) -> int:
    """定时抓 PNG 画面（Page.captureScreenshot，无损）。

    不用 Page.startScreencast：它只在**画面变化**时发帧，静态页面几秒才一帧，
    合成出来会卡。定时轮询帧率可控（默认 10fps），且 PNG 无损 —— 1px 细边框不会像
    JPEG 那样被压掉，因此**不需要给页面注入任何增强样式**。
    """
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.startswith("frame-") or f == "frames.tsv":
            os.remove(os.path.join(out_dir, f))

    # Chrome 会拒绝带 Origin 头的外部 WebSocket（403），suppress_origin 即绕开
    ws = websocket.create_connection(page_ws_url(port), timeout=15, max_size=None,
                                     suppress_origin=True)
    msg_id = 0

    def send(method, params=None):
        nonlocal msg_id
        msg_id += 1
        ws.send(json.dumps({"id": msg_id, "method": method, "params": params or {}}))
        return msg_id

    send("Page.enable")
    # 直接覆盖视口尺寸：不依赖 Chrome 窗口大小（headless 下窗口高度会被 UI 吃掉一截，
    # 实测 1920x1080 的窗口只给到 1920x937，h264 还要求偶数高度）
    send("Emulation.setDeviceMetricsOverride", {
        "width": width, "height": height, "deviceScaleFactor": 1, "mobile": False,
    })

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    t0 = time.time()
    n = 0
    with open(os.path.join(out_dir, "frames.tsv"), "w", encoding="utf-8") as meta:
        meta.write("# frame\tms\n")
        while RUNNING:
            mid = send("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
            data = None
            while RUNNING:
                msg = json.loads(ws.recv())
                if msg.get("id") == mid:
                    res = msg.get("result") or {}
                    if res.get("data"):
                        data = base64.b64decode(res["data"])
                    break
            if data:
                with open(os.path.join(out_dir, f"frame-{n:05d}.png"), "wb") as fp:
                    fp.write(data)
                meta.write(f"{n}\t{int((time.time() - t0) * 1000)}\n")
                meta.flush()
                n += 1
            time.sleep(max(interval_ms, 0) / 1000.0)

    ws.close()
    print(f"抓到 {n} 帧 → {out_dir}（{time.time() - t0:.1f}s）")
    return 0 if n > 0 else 1


def cmd_mp4(frames_dir: str, out_mp4: str, fps: int) -> int:
    out_mp4 = os.path.abspath(out_mp4)   # ffmpeg 的 cwd 在帧目录里
    meta_path = os.path.join(frames_dir, "frames.tsv")
    if not os.path.exists(meta_path):
        sys.exit(f"缺少 {meta_path}")
    times = []
    with open(meta_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            idx, ms = line.split("\t")
            times.append((int(idx), int(ms)))
    if not times:
        sys.exit("frames.tsv 为空")
    # 用 image2 序列合成：录的是**定时轮询**（默认 100ms），帧间隔基本均匀，
    # 按实测平均间隔换算出输入帧率即可还原真实节奏（concat demuxer 对 PNG 序列不友好）。
    n = len(times)
    span_ms = times[-1][1] - times[0][1]
    avg_ms = (span_ms / (n - 1)) if n > 1 and span_ms > 0 else 100.0
    fps_in = 1000.0 / avg_ms
    cmd = [
        "ffmpeg", "-y", "-v", "error",
        "-framerate", f"{fps_in:.4f}", "-i", "frame-%05d.png",
        # 视口高度可能是奇数（实测 1920x937）→ h264 要求偶数，补一行
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-r", str(fps), "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", out_mp4,
    ]
    r = subprocess.run(cmd, cwd=frames_dir)
    if r.returncode != 0:
        return r.returncode
    print(f"合成 {out_mp4}（{n} 帧 / {span_ms/1000:.1f}s / 输入 {fps_in:.2f}fps → 输出 {fps}fps）")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == "rec":
        out_dir = sys.argv[2]
        port = 9222
        if "--port" in sys.argv:
            port = int(sys.argv[sys.argv.index("--port") + 1])
        interval = 100
        if "--interval" in sys.argv:
            interval = int(sys.argv[sys.argv.index("--interval") + 1])
        width, height = 1920, 1080
        if "--size" in sys.argv:
            w, h = sys.argv[sys.argv.index("--size") + 1].lower().split("x")
            width, height = int(w), int(h)
        return cmd_rec(out_dir, port, interval, width, height)
    if mode == "mp4":
        frames_dir, out_mp4 = sys.argv[2], sys.argv[3]
        fps = 30
        if "--fps" in sys.argv:
            fps = int(sys.argv[sys.argv.index("--fps") + 1])
        return cmd_mp4(frames_dir, out_mp4, fps)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
