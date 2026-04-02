#!/bin/bash
# Clone/update the World Cup Bet repo, then start OpenFang

REPO_DIR="/app/repos/world-cup-bet"

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

exec openfang start
