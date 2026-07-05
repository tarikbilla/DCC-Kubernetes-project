"""
DCC Kubernetes Demo — FastAPI application.

Every response includes the pod's hostname so that scaling, self-healing
and rolling updates are directly visible in the browser.

Endpoints:
    GET /          -> demo web page (static HTML, polls /api/info)
    GET /api/info  -> JSON: pod name, version, uptime, request counter
    GET /healthz   -> liveness/readiness probe target
    GET /crash     -> kills this pod's process (self-healing demo)
    GET /load      -> burns CPU for N seconds (autoscaling demo)
"""

import os
import socket
import threading
import time
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse

APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
POD_NAME = socket.gethostname()  # inside K8s this is the pod name
STARTED_AT = time.time()

# Major version -> accent color, so a rolling update is visible as a color change.
VERSION_COLORS = {"1": "#3b82f6", "2": "#22c55e", "3": "#f59e0b"}
COLOR = VERSION_COLORS.get(APP_VERSION.split(".")[0], "#a855f7")

app = FastAPI(title="DCC Kubernetes Demo", version=APP_VERSION)

_request_count = 0
_count_lock = threading.Lock()

STATIC_DIR = Path(__file__).parent


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/info")
def info() -> dict:
    global _request_count
    with _count_lock:
        _request_count += 1
        count = _request_count
    return {
        "pod": POD_NAME,
        "version": APP_VERSION,
        "color": COLOR,
        "uptime_seconds": round(time.time() - STARTED_AT, 1),
        "requests_served_by_this_pod": count,
    }


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok", "pod": POD_NAME}


@app.get("/crash")
def crash() -> dict:
    """Exit the process shortly after responding.

    The container dies with a non-zero exit code; Kubernetes' restartPolicy
    (Always) restarts it automatically — that restart is the self-healing demo.
    """
    threading.Timer(0.3, os._exit, args=(1,)).start()
    return {"message": f"Pod {POD_NAME} is crashing now — watch Kubernetes restart it."}


@app.get("/load")
def load(seconds: int = 15) -> dict:
    """Busy-loop to consume CPU so the HorizontalPodAutoscaler reacts.

    Declared as a sync `def` so FastAPI runs it in the thread pool and the
    health endpoints stay responsive while the CPU burns.
    """
    seconds = max(1, min(seconds, 30))
    end = time.time() + seconds
    iterations = 0
    while time.time() < end:
        sum(i * i for i in range(10_000))
        iterations += 1
    return {"pod": POD_NAME, "burned_seconds": seconds, "iterations": iterations}
