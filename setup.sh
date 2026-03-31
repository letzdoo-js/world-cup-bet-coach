#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ClawBot v2 Docker Setup — Adaptive Learning Mentor
# ============================================================
# Usage :
#   chmod +x setup.sh
#   ./setup.sh
#
# Pre-requis :
#   - Docker avec compose
#   - config.json rempli (copié depuis config.json.template)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
VOLUME_NAME="world-cup-bet-coach_world-cup-bet-workspace"

# --- 1. Check config.json ---
echo "1/3 — Vérification de config.json..."
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$SCRIPT_DIR/config.json.template" "$CONFIG_FILE"
    echo "   config.json créé depuis le template."
    echo "   IMPORTANT : édite config.json avant de relancer :"
    echo "     nano $CONFIG_FILE"
    exit 1
fi

if grep -q "REPLACE_" "$CONFIG_FILE"; then
    echo "   WARNING : config.json contient encore des placeholders REPLACE_*"
    echo "   Édite le fichier : nano $CONFIG_FILE"
    exit 1
fi
echo "   OK"

# --- 2. Build + start ---
echo ""
echo "2/3 — Build et lancement..."
cd "$SCRIPT_DIR"
docker compose up -d --build
echo "   OK"

# --- 3. Seed workspace volume if empty ---
echo ""
echo "3/3 — Initialisation du workspace..."
CONTAINER="clawbot"
WORKSPACE_DIR="/root/.nanobot/workspace"

if ! docker exec "$CONTAINER" test -f "$WORKSPACE_DIR/curriculum.json" 2>/dev/null; then
    echo "   Premier lancement — copie des fichiers workspace..."
    docker cp "$SCRIPT_DIR/workspace/curriculum.json" "$CONTAINER:$WORKSPACE_DIR/"
    docker cp "$SCRIPT_DIR/workspace/progress.json" "$CONTAINER:$WORKSPACE_DIR/"
    echo "   OK"
else
    echo "   Workspace déjà initialisé (volume persistant)"
fi

echo ""
echo "=== ClawBot v2 lancé — Mentor Adaptatif ==="
echo ""
echo "  Logs     : docker compose logs -f"
echo "  Stop     : docker compose down"
echo "  Restart  : docker compose restart"
echo "  Rebuild  : ./setup.sh"
echo "  Reset    : docker volume rm $VOLUME_NAME && ./setup.sh"
echo ""
