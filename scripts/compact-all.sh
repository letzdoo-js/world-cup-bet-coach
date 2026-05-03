#!/usr/bin/env bash
#
# compact-all.sh — trigger LLM-based session compaction for every agent.
#
# Why this exists: openfang's auto-compaction (`SessionStore::append_canonical`
# at >100 messages) uses a poor text-truncation summary (200 chars/msg, cap
# 4000 chars total, drops tool_use blocks entirely). The smart LLM-based
# compaction (`compact_session_kernel` → `store_llm_summary`) only fires when
# someone POSTs `/api/agents/{id}/session/compact` — there is no automatic
# trigger upstream.
#
# Run this script nightly (host cron / systemd-timer) so each agent gets a
# proper LLM summary before its session crosses the threshold and the lossy
# auto-compaction kicks in. Cost is bounded: the kernel checks
# `needs_compaction()` first and returns "No compaction needed" without an
# LLM call if the session is short.
#
# Calls the API from INSIDE the container via loopback (no API key needed).
#
# Usage:  ./scripts/compact-all.sh
#
# Suggested cron line (host):
#   0 2 * * *  /home/coder/world-cup-bet-coach/scripts/compact-all.sh >> /var/log/compact-all.log 2>&1
set -euo pipefail

CONTAINER="${OPENFANG_CONTAINER:-world-cup-bet-coach}"
PY_PATH="/app/compact-all.py"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container $CONTAINER not running" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker cp "$SCRIPT_DIR/compact-all.py" "$CONTAINER:$PY_PATH"
docker exec "$CONTAINER" python3 "$PY_PATH"
