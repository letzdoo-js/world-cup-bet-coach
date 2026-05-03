"""Companion to compact-all.sh — runs INSIDE the container."""
import json
import sys
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:4200"


def call(method, path, body=None, timeout=120):
    """Compaction can take several seconds (LLM call) — generous timeout."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{API}{path}",
        method=method,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
    try:
        return r.status, json.loads(raw)
    except json.JSONDecodeError:
        return r.status, raw


print(f"=== compact-all @ {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} ===")

_, agents = call("GET", "/api/agents")
if not isinstance(agents, list):
    print(f"  unexpected /api/agents response: {agents!r}")
    sys.exit(1)

exit_code = 0
for a in agents:
    aid = a["id"]
    name = a.get("name", "?")
    state = a.get("state", "?")
    if state != "Running":
        print(f"  {name:25s} ({aid[:8]}): state={state}, skip")
        continue
    t0 = time.time()
    try:
        status, body = call("POST", f"/api/agents/{aid}/session/compact")
        elapsed = time.time() - t0
        msg = body.get("message", body) if isinstance(body, dict) else body
        print(f"  {name:25s} ({aid[:8]}): HTTP {status} ({elapsed:.1f}s) {msg}")
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        err_body = e.read().decode()[:200]
        print(f"  {name:25s} ({aid[:8]}): HTTP {e.code} ({elapsed:.1f}s) {err_body}")
        exit_code = 1
    except Exception as e:
        elapsed = time.time() - t0
        print(f"  {name:25s} ({aid[:8]}): ERROR ({elapsed:.1f}s) {e}")
        exit_code = 1

sys.exit(exit_code)
