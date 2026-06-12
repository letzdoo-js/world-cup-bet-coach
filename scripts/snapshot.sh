#!/bin/bash
# Snapshot and restore OpenFang state via Docker volumes.
#
# Usage:
#   ./scripts/snapshot.sh save [name]      # Save current state (default name: latest)
#   ./scripts/snapshot.sh restore [name]   # Restore state (stops/starts container)
#   ./scripts/snapshot.sh list             # List saved snapshots
#   ./scripts/snapshot.sh delete <name>    # Delete a snapshot
#
# Workflow:
#   1. ./scripts/snapshot.sh save before-test
#   2. ... interact via Telegram, API, whatever ...
#   3. ./scripts/snapshot.sh restore before-test
#
# The snapshot copies the entire /app volume (KV store, sessions, config, repos).

set -euo pipefail

CONTAINER="world-cup-bet-coach"
COMPOSE_DIR="$HOME/world-cup-bet-coach"
SNAPSHOT_DIR="$COMPOSE_DIR/snapshots"

mkdir -p "$SNAPSHOT_DIR"

cmd="${1:-help}"
name="${2:-latest}"

case "$cmd" in
    save)
        echo "=== Saving snapshot: $name ==="

        # Must be running to copy from volume
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            echo "Error: container $CONTAINER is not running"
            exit 1
        fi

        SNAP="$SNAPSHOT_DIR/$name"
        rm -rf "$SNAP"
        mkdir -p "$SNAP"

        # Copy entire /app from container
        docker cp "$CONTAINER:/app" "$SNAP/app"

        # Save metadata
        echo "{\"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"name\": \"$name\"}" > "$SNAP/metadata.json"

        # Save agent list
        docker exec "$CONTAINER" openfang agent list > "$SNAP/agents.txt" 2>&1

        SIZE=$(du -sh "$SNAP" | cut -f1)
        echo "✓ Snapshot saved: $SNAP ($SIZE)"
        echo "  Agents:"
        cat "$SNAP/agents.txt"
        ;;

    restore)
        SNAP="$SNAPSHOT_DIR/$name"
        if [ ! -d "$SNAP/app" ]; then
            echo "Error: snapshot '$name' not found at $SNAP"
            echo "Available snapshots:"
            ls -1 "$SNAPSHOT_DIR" 2>/dev/null || echo "  (none)"
            exit 1
        fi

        echo "=== Restoring snapshot: $name ==="
        cat "$SNAP/metadata.json"
        echo ""

        # Stop container
        echo "Stopping container..."
        cd "$COMPOSE_DIR"
        docker compose down 2>/dev/null || true

        # Get volume mount point
        VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep "coach-data" | head -1)
        if [ -z "$VOLUME_NAME" ]; then
            echo "Error: coach-data volume not found"
            exit 1
        fi

        # Restore volume contents via a temp container.
        # We use `docker cp` (not a bind mount) so this works in docker-in-docker
        # setups where the host snapshot dir isn't visible to the docker daemon.
        echo "Restoring volume..."
        TMP_NAME="snapshot-restore-$$"
        docker run -d --name "$TMP_NAME" -v "$VOLUME_NAME:/app" alpine sleep 300 >/dev/null
        trap "docker rm -f $TMP_NAME >/dev/null 2>&1 || true" EXIT
        docker exec "$TMP_NAME" sh -c 'rm -rf /app/* /app/.[!.]* 2>/dev/null; true'
        docker cp "$SNAP/app/." "$TMP_NAME:/app/"
        docker rm -f "$TMP_NAME" >/dev/null
        trap - EXIT

        # Start container
        echo "Starting container..."
        docker compose up coach -d
        sleep 8

        # Verify
        echo ""
        echo "✓ Snapshot restored"
        docker exec "$CONTAINER" openfang agent list 2>&1
        ;;

    list)
        echo "=== Snapshots ==="
        if [ ! -d "$SNAPSHOT_DIR" ] || [ -z "$(ls -A "$SNAPSHOT_DIR" 2>/dev/null)" ]; then
            echo "  (none)"
            exit 0
        fi
        for snap in "$SNAPSHOT_DIR"/*/; do
            snap_name=$(basename "$snap")
            if [ -f "$snap/metadata.json" ]; then
                ts=$(python3 -c "import json; print(json.load(open('$snap/metadata.json'))['timestamp'])" 2>/dev/null || echo "?")
                size=$(du -sh "$snap" | cut -f1)
                echo "  $snap_name — $ts ($size)"
            fi
        done
        ;;

    delete)
        SNAP="$SNAPSHOT_DIR/$name"
        if [ -d "$SNAP" ]; then
            rm -rf "$SNAP"
            echo "✓ Deleted snapshot: $name"
        else
            echo "Snapshot '$name' not found"
        fi
        ;;

    *)
        echo "Usage: $0 {save|restore|list|delete} [name]"
        echo ""
        echo "  save [name]     Save current state (default: latest)"
        echo "  restore [name]  Stop container, restore state, restart"
        echo "  list            List saved snapshots"
        echo "  delete <name>   Delete a snapshot"
        echo ""
        echo "Workflow:"
        echo "  $0 save before-test"
        echo "  ... interact via Telegram ..."
        echo "  $0 restore before-test"
        ;;
esac
