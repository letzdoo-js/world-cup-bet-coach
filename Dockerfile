FROM python:3.12-slim

# Install nanobot from local source (patched: forwards all /commands to the agent)
COPY nanobot/ /tmp/nanobot/
RUN pip install --no-cache-dir /tmp/nanobot/ && rm -rf /tmp/nanobot/

# Nanobot workspace lives in /root/.nanobot/workspace
ENV NANOBOT_DIR=/root/.nanobot
RUN mkdir -p "$NANOBOT_DIR/workspace/skills" "$NANOBOT_DIR/workspace/memory"

# Copy skills (baked into image)
COPY skills/ $NANOBOT_DIR/workspace/skills/

# Copy workspace bootstrap files (SOUL, AGENTS, USER, TOOLS, HEARTBEAT)
COPY workspace/SOUL.md workspace/AGENTS.md workspace/USER.md workspace/TOOLS.md workspace/HEARTBEAT.md $NANOBOT_DIR/workspace/

# Copy initial memory template
COPY workspace/memory/MEMORY.md $NANOBOT_DIR/workspace/memory/

# Copy config
COPY config.json $NANOBOT_DIR/config.json

# Workspace data (curriculum, progress) is mounted via docker-compose volume
CMD ["nanobot", "gateway"]
