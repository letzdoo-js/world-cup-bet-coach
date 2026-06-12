#!/bin/bash
# Test an agent without affecting production state.
# Usage:
#   ./scripts/test-agent.sh leandro "Salut !"
#   ./scripts/test-agent.sh leandro "Salut !" "C'est quoi une API ?" "Comment je fais un git push ?"
#   ./scripts/test-agent.sh magnus "Rapport sur William"
#
# What it does:
#   1. Saves current KV state for the agent
#   2. Sends each message and prints the response
#   3. Restores KV state and resets the session

set -euo pipefail

CONTAINER="world-cup-bet-coach"
API="http://127.0.0.1:4200"
AGENT_NAME="${1:?Usage: $0 <agent_name> <message> [message2] [message3] ...}"
shift

if [ $# -eq 0 ]; then
    echo "Error: provide at least one message"
    echo "Usage: $0 <agent_name> <message> [message2] ..."
    exit 1
fi

# --- Resolve agent ID ---
AGENT_ID=$(docker exec "$CONTAINER" python3 -c "
import urllib.request, json
agents = json.loads(urllib.request.urlopen('$API/api/agents').read())
for a in agents:
    if a['name'] == '$AGENT_NAME':
        print(a['id'])
        break
" 2>/dev/null)

if [ -z "$AGENT_ID" ]; then
    echo "Error: agent '$AGENT_NAME' not found"
    exit 1
fi

echo "=== Test session: $AGENT_NAME ($AGENT_ID) ==="
echo ""

# --- Save KV state ---
BACKUP_FILE="/tmp/kv-backup-${AGENT_NAME}-$$.json"
docker exec "$CONTAINER" python3 -c "
import urllib.request, json
data = json.loads(urllib.request.urlopen('$API/api/memory/agents/$AGENT_NAME/kv').read())
print(json.dumps(data))
" > "$BACKUP_FILE" 2>/dev/null

echo "✓ KV state saved ($BACKUP_FILE)"
echo ""

# --- Send messages ---
MSG_NUM=0
TOTAL_COST=0
for MSG in "$@"; do
    MSG_NUM=$((MSG_NUM + 1))
    echo "────────────────────────────────────────"
    echo "► Message $MSG_NUM: $MSG"
    echo "────────────────────────────────────────"

    RESPONSE=$(docker exec "$CONTAINER" python3 -c "
import urllib.request, json, sys
data = json.dumps({'message': '''$MSG'''}).encode()
req = urllib.request.Request('$API/api/agents/$AGENT_ID/message', data=data, headers={'Content-Type': 'application/json'})
try:
    r = urllib.request.urlopen(req, timeout=120)
    resp = json.loads(r.read())
    print(resp.get('response', '[no response]'))
    print('---STATS---')
    print(f'iterations={resp.get(\"iterations\",0)} cost=\${resp.get(\"cost_usd\",0):.4f} in={resp.get(\"input_tokens\",0)} out={resp.get(\"output_tokens\",0)}')
except Exception as e:
    print(f'ERROR: {e}')
    print('---STATS---')
    print('iterations=0 cost=\$0.0000 in=0 out=0')
" 2>/dev/null)

    # Split response and stats
    REPLY=$(echo "$RESPONSE" | sed '/^---STATS---$/,$d')
    STATS=$(echo "$RESPONSE" | sed -n '/^---STATS---$/,$ p' | tail -1)

    echo ""
    echo "$REPLY"
    echo ""
    echo "  [$STATS]"
    echo ""

    # Accumulate cost
    COST=$(echo "$STATS" | grep -oP 'cost=\$\K[0-9.]+' || echo "0")
    TOTAL_COST=$(python3 -c "print($TOTAL_COST + $COST)")
done

echo "════════════════════════════════════════"
echo "Total: $MSG_NUM messages, cost \$$TOTAL_COST"
echo "════════════════════════════════════════"
echo ""

# --- Restore KV state ---
echo "Restoring KV state..."

docker cp "$BACKUP_FILE" "$CONTAINER:/tmp/kv-restore.json"
docker exec "$CONTAINER" python3 -c "
import urllib.request, json

backup = json.load(open('/tmp/kv-restore.json'))
kv_pairs = backup.get('kv_pairs', [])

for kv in kv_pairs:
    key = kv['key']
    value = kv['value']
    try:
        json.loads(value)
        payload = value
    except (json.JSONDecodeError, TypeError):
        payload = json.dumps(value)

    data = json.dumps({'value': payload}).encode()
    req = urllib.request.Request(
        '$API/api/memory/agents/$AGENT_NAME/kv/' + key,
        data=data,
        headers={'Content-Type': 'application/json'},
        method='PUT'
    )
    urllib.request.urlopen(req)

print(f'✓ {len(kv_pairs)} KV keys restored')
" 2>/dev/null

# --- Reset session ---
docker exec "$CONTAINER" python3 -c "
import urllib.request
req = urllib.request.Request('$API/api/agents/$AGENT_ID/session/reset', method='POST', data=b'{}')
urllib.request.urlopen(req)
print('✓ Session reset')
" 2>/dev/null

rm -f "$BACKUP_FILE"
echo ""
echo "=== Test complete — agent state restored ==="
