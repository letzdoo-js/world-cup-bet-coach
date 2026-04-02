#!/bin/bash
# Clone/update the World Cup Bet repo, then start OpenFang

REPO_DIR="/app/workspaces/world-cup-bet"

if [ -d "$REPO_DIR/.git" ]; then
    echo "Updating world-cup-bet repo..."
    cd "$REPO_DIR" && git pull --ff-only 2>/dev/null || true
else
    echo "Cloning world-cup-bet repo..."
    mkdir -p /app/repos
    git clone git@github.com:letzdoo-js/world-cup-bet.git "$REPO_DIR" 2>/dev/null || {
        echo "SSH clone failed, trying HTTPS..."
        git clone https://github.com/letzdoo-js/world-cup-bet.git "$REPO_DIR" 2>/dev/null || {
            echo "WARNING: Could not clone repo. Agents won't have code access."
        }
    }
fi

# Copy repo into each agent workspace (symlinks blocked by sandbox)
for agent_dir in /app/workspaces/*/; do
    agent_name=$(basename "$agent_dir")
    if [ "$agent_name" != "world-cup-bet" ] && [ ! -d "$agent_dir/world-cup-bet/.git" ]; then
        cp -r /app/workspaces/world-cup-bet "$agent_dir/world-cup-bet" 2>/dev/null || true
    fi
done

exec openfang start --yolo
