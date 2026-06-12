#!/bin/bash
# Interactive chat with an agent — simulates Telegram conversation.
#
# Usage:
#   ./scripts/chat.sh leandro    # Chat as William
#   ./scripts/chat.sh magnus     # Chat as Jerome
#
# Type your message and press Enter. Type 'quit' or Ctrl+C to exit.

set -euo pipefail

CONTAINER="world-cup-bet-coach"
API="http://127.0.0.1:4200"
AGENT_NAME="${1:-leandro}"

# Resolve agent ID
AGENT_ID=$(docker exec "$CONTAINER" python3 -c "
import urllib.request, json
agents = json.loads(urllib.request.urlopen('$API/api/agents').read())
for a in agents:
    if a['name'] == '$AGENT_NAME':
        print(a['id'])
        break
" 2>/dev/null)

if [ -z "$AGENT_ID" ]; then
    echo "Agent '$AGENT_NAME' not found"
    exit 1
fi

TOTAL_COST=0
MSG_COUNT=0

echo "╔══════════════════════════════════════════╗"
echo "║  Chat with $AGENT_NAME"
echo "║  Type 'quit' to exit, 'reset' to clear session"
echo "╚══════════════════════════════════════════╝"
echo ""

while true; do
    printf "\033[1;34mToi >\033[0m "
    read -r MSG || break

    [ "$MSG" = "quit" ] && break
    [ -z "$MSG" ] && continue

    if [ "$MSG" = "reset" ]; then
        docker exec "$CONTAINER" python3 -c "
import urllib.request
req = urllib.request.Request('$API/api/agents/$AGENT_ID/session/reset', method='POST', data=b'{}')
urllib.request.urlopen(req)
" 2>/dev/null
        echo "  (session reset)"
        echo ""
        continue
    fi

    # Escape message for JSON
    ESCAPED=$(python3 -c "import json; print(json.dumps($( python3 -c "import sys; print(repr('$MSG'))" )))")

    RESPONSE=$(docker exec "$CONTAINER" python3 -c "
import urllib.request, json, sys
data = json.dumps({'message': $ESCAPED}).encode()
req = urllib.request.Request('$API/api/agents/$AGENT_ID/message', data=data, headers={'Content-Type': 'application/json'})
try:
    r = urllib.request.urlopen(req, timeout=120)
    resp = json.loads(r.read())
    response = resp.get('response', '[no response]')
    cost = resp.get('cost_usd', 0)
    iters = resp.get('iterations', 0)
    print(response)
    print(f'__COST__={cost}')
    print(f'__ITERS__={iters}')
except Exception as e:
    print(f'Error: {e}')
    print('__COST__=0')
    print('__ITERS__=0')
" 2>/dev/null)

    REPLY=$(echo "$RESPONSE" | grep -v "^__COST__=\|^__ITERS__=")
    COST=$(echo "$RESPONSE" | grep "^__COST__=" | cut -d= -f2)
    ITERS=$(echo "$RESPONSE" | grep "^__ITERS__=" | cut -d= -f2)

    echo ""
    printf "\033[1;32m$AGENT_NAME >\033[0m "
    echo "$REPLY"
    echo ""
    printf "\033[2m  [\$${COST:-0} · ${ITERS:-0} iter]\033[0m\n"
    echo ""

    MSG_COUNT=$((MSG_COUNT + 1))
    TOTAL_COST=$(python3 -c "print(${TOTAL_COST} + ${COST:-0})")
done

echo ""
echo "── Session: $MSG_COUNT messages, total \$$TOTAL_COST ──"
