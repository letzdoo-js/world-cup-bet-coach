#!/usr/bin/env bash
#
# wake-all.sh — re-enable cron jobs + start suspended agents.
#
# Run this after a `docker compose up` / image rebuild / cold boot, when:
#   - agents are stuck in "suspended" (cold start, no recent trigger)
#   - cron jobs are persisted but `enabled: false`
#
# Calls the API from INSIDE the container via loopback (127.0.0.1) — upstream
# >= v0.6.x requires an API key for non-loopback requests, but loopback is
# unauthed by design.
#
# Idempotent: agents already Running stay Running, cron jobs already enabled
# stay enabled.
#
# Implementation note: heredoc-piped Python via `docker exec` is silent on
# this stack (see CLAUDE.md "Pièges opérationnels"). We write the script to
# /tmp inside the container then exec it — that path produces visible stdout.
#
# Usage:  ./scripts/wake-all.sh
set -euo pipefail

CONTAINER="${OPENFANG_CONTAINER:-world-cup-bet-coach}"
PY_PATH="/app/wake-all.py"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container $CONTAINER not running" >&2
  exit 1
fi

# Wait for /api/health from inside the container (loopback).
for i in $(seq 1 10); do
  if docker exec "$CONTAINER" python3 -c "
import urllib.request, sys
try:
    urllib.request.urlopen('http://127.0.0.1:4200/api/health', timeout=2).read()
except Exception:
    sys.exit(1)
" 2>/dev/null; then break; fi
  echo "  ...waiting for API ($i/10)"
  sleep 1
done

# Ship the python script into the container, then exec it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker cp "$SCRIPT_DIR/wake-all.py" "$CONTAINER:$PY_PATH"
docker exec "$CONTAINER" python3 "$PY_PATH"
