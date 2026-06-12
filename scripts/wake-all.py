"""Companion to wake-all.sh — runs INSIDE the container."""
import json
import sys
import urllib.error
import urllib.request

API = "http://127.0.0.1:4200"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{API}{path}",
        method=method,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read().decode()
    try:
        return r.status, json.loads(raw)
    except json.JSONDecodeError:
        return r.status, raw


# --- 1/2: Enable all cron jobs ---
print("=== 1/2 — Enabling all cron jobs ===")
_, jobs_payload = call("GET", "/api/cron/jobs")
jobs = jobs_payload.get("jobs", []) if isinstance(jobs_payload, dict) else []
if not jobs:
    print("  (no cron jobs found)")
for j in jobs:
    jid = j["id"]
    name = j.get("name", "?")
    was = j.get("enabled", False)
    if was:
        print(f"  {name} ({jid[:8]}): already enabled, skip")
        continue
    status, body = call("PUT", f"/api/cron/jobs/{jid}/enable", {"enabled": True})
    print(f"  {name} ({jid[:8]}): HTTP {status} {body}")

# --- 2/2: Start suspended agents ---
print()
print("=== 2/2 — Starting suspended agents ===")
_, agents = call("GET", "/api/agents")
if not isinstance(agents, list):
    print(f"  unexpected /api/agents response: {agents!r}")
    sys.exit(1)
for a in agents:
    aid = a["id"]
    name = a.get("name", "?")
    state = a.get("state", "?")
    if state == "Running":
        print(f"  {name:25s} ({aid[:8]}): already Running, skip")
        continue
    try:
        status, body = call("POST", f"/api/agents/{aid}/start")
        print(f"  {name:25s} ({aid[:8]}): start → HTTP {status} {body}")
    except urllib.error.HTTPError as e:
        print(f"  {name:25s} ({aid[:8]}): start → HTTP {e.code} {e.read().decode()[:200]}")

# --- Final state ---
print()
print("=== Final state ===")
_, agents = call("GET", "/api/agents")
for a in agents:
    print(f"  {a.get('name', '?'):25s} {a.get('state', '?')}")
