#!/bin/bash
# Send a message to an agent and print the response.
#
# Usage:
#   ./scripts/send.sh leandro "Salut !"
#   ./scripts/send.sh magnus "Rapport"

set -euo pipefail

CONTAINER="world-cup-bet-coach"
API="http://127.0.0.1:4200"
AGENT_NAME="${1:?Usage: $0 <agent_name> <message>}"
MSG="${2:?Usage: $0 <agent_name> <message>}"

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

docker exec "$CONTAINER" python3 -c "
import urllib.request, json
data = json.dumps({'message': '''$MSG'''}).encode()
req = urllib.request.Request('$API/api/agents/$AGENT_ID/message', data=data, headers={'Content-Type': 'application/json'})
r = urllib.request.urlopen(req, timeout=120)
resp = json.loads(r.read())
print(resp.get('response', '[no response]'))
print()
print(f'[iterations={resp.get(\"iterations\",0)} cost=\${resp.get(\"cost_usd\",0):.4f} in={resp.get(\"input_tokens\",0)} out={resp.get(\"output_tokens\",0)}]')
" 2>/dev/null
