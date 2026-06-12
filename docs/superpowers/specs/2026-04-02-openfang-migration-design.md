# OpenFang Migration Design

## Context

The nanobot-based World Cup Bet Coach burned ~$27/day due to architectural flaws: no cron deduplication (9 overlapping jobs), O(n^2) context accumulation, and no cost visibility. Beyond cost, it had critical pedagogical failures:

- **Repeated lessons** — forgot where William was between sessions
- **Random curriculum jumps** — skipped competencies, no structured progression
- **Ignored parent instructions** — Jerome's pedagogical direction wasn't reliably applied
- **User confusion** — mixed up William and Jerome in the same conversation context

Root cause: nothing enforced state reads/writes. The bot could ignore `progress.json` and `MEMORY.md` and the system wouldn't stop it. Context bloat from a single agent handling both users made everything worse.

## Goals

1. Eliminate context bloat — fresh sessions, structured state reads
2. Enforce state discipline — mandatory read-before-respond, write-after-progress
3. Separate users structurally — William and Jerome never share an agent or context
4. Keep pedagogical quality — guided exploration with World Cup Bet app as north star
5. Enable active co-piloting — Jerome's instructions apply immediately
6. Cut costs to ~$1-2/day from ~$27/day

## Architecture: 3 Agents

```
┌─────────────────────────────────────────────────────┐
│                   OpenFang Runtime                    │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐ │
│  │   tutor      │  │   parent    │  │  engagement   │ │
│  │  (Sonnet)    │  │  (Sonnet)   │  │  (Haiku)     │ │
│  │             │  │             │  │              │ │
│  │ Talks to:   │  │ Talks to:   │  │ Talks to:    │ │
│  │ William     │  │ Jerome      │  │ nobody       │ │
│  │             │  │             │  │ (triggers    │ │
│  │ Reads:      │  │ Reads:      │  │  tutor)      │ │
│  │ shared.*    │  │ shared.*    │  │              │ │
│  │ self.*      │  │ self.*      │  │ Reads:       │ │
│  │             │  │             │  │ shared.prog  │ │
│  │ Writes:     │  │ Writes:     │  │              │ │
│  │ shared.prog │  │ shared.curr │  │ Cron: 16h,19h│ │
│  │ self.*      │  │ self.*      │  └──────────────┘ │
│  └──────┬──────┘  └──────┬──────┘                    │
│         │                │                            │
│         ▼                ▼                            │
│  ┌─────────────────────────────────┐                 │
│  │       Shared KV Store (SQLite)  │                 │
│  │                                  │                 │
│  │  shared.progress   ← tutor W    │                 │
│  │  shared.curriculum ← parent W   │                 │
│  │  shared.competencies ← tutor W  │                 │
│  │  shared.goals      ← parent W   │                 │
│  │  shared.learning_style ← tutor W│                 │
│  └─────────────────────────────────┘                 │
│                                                       │
│  ┌─────────────────────────────────┐                 │
│  │     Telegram Channel Adapter    │                 │
│  │  8685378493 → tutor             │                 │
│  │  8233154700 → parent            │                 │
│  └─────────────────────────────────┘                 │
└─────────────────────────────────────────────────────┘
```

### Why 3 agents, not 1

- **No context bloat**: each agent gets a fresh session, loads only what it needs from KV
- **No user confusion**: tutor only sees William, parent only sees Jerome — structurally impossible to mix up
- **Separation of concerns**: easier to iterate on tutor behavior without affecting parent experience
- **Cheap monitoring**: engagement-monitor runs Haiku with 5k tokens/hour budget

### Communication model

Agents communicate through **shared KV state**, not real-time messages. Jerome writes curriculum via parent agent, tutor reads it on next William message. No synchronization bugs, no message ordering issues.

The one exception: engagement-monitor uses `agent_send` to trigger tutor when William has been inactive >48h.

## Shared State Schema

| Key | Written by | Read by | Content |
|---|---|---|---|
| `shared.progress` | tutor | all | `{ xp, level, last_active, current_mission, daily_streak }` |
| `shared.competencies` | tutor | parent, tutor | `{ [competency_id]: { level, first_seen, last_discussed, evidence[] } }` |
| `shared.curriculum` | parent | tutor, engagement | `{ week_plan, priority_domains[], pace, notes }` |
| `shared.goals` | parent | tutor | `{ milestones: [{ name, description, target_date, status }] }` |
| `shared.learning_style` | tutor | parent | `{ observations[], what_works[], what_doesnt[] }` |

### Mandatory state protocol

Every agent system prompt enforces:

```
ON EVERY MESSAGE:
1. memory_recall shared.progress
2. memory_recall shared.curriculum
3. memory_recall [agent-specific keys]
4. [handle the message]
5. memory_store any changed keys
```

This is the core fix for nanobot's "forgetting" problem.

## Agent Definitions

### Tutor Agent

```toml
name = "tutor"
version = "1.0.0"
description = "Coding coach for William — guides World Cup Bet app development"
author = "jerome"
module = "builtin:chat"
tags = ["education", "coding", "mentor"]

[model]
provider = "anthropic"
model = "claude-sonnet-4-20250514"

[resources]
max_llm_tokens_per_hour = 100000

[capabilities]
tools = ["memory_store", "memory_recall", "file_read"]
memory_read = ["*"]
memory_write = ["self.*", "shared.progress", "shared.competencies", "shared.learning_style"]
agent_spawn = false
```

**System prompt responsibilities:**
- Read shared state before every response
- Coach William toward building the World Cup Bet app
- Follow `shared.curriculum` priorities set by Jerome (weave naturally, never say "your dad said...")
- Track competency progression: undiscovered -> discovered -> understood -> applied -> mastered
- Award XP on progression, maintain gamification (levels, streaks, badges)
- Never re-teach competencies already at "understood" or above — build on them
- Update `shared.progress` and `shared.competencies` after meaningful exchanges
- Log learning style observations to `shared.learning_style`
- Tone: cool older dev mentor, French with English tech terms, micro-steps, Socratic method
- Reference `curriculum.json` (via file_read) for competency definitions and discovery hooks

### Parent Agent

```toml
name = "parent"
version = "1.0.0"
description = "Jerome's interface — progress reports and pedagogical control"
author = "jerome"
module = "builtin:chat"
tags = ["education", "reporting", "admin"]

[model]
provider = "anthropic"
model = "claude-sonnet-4-20250514"

[resources]
max_llm_tokens_per_hour = 50000

[capabilities]
tools = ["memory_store", "memory_recall", "file_read"]
memory_read = ["*"]
memory_write = ["self.*", "shared.curriculum", "shared.goals"]
agent_spawn = false
```

**System prompt responsibilities:**
- Read shared state before every response
- Report William's progress honestly with data (XP, competencies, streaks, observations)
- When Jerome gives instructions, write to `shared.curriculum` immediately
- Manage `shared.goals` — milestones for the World Cup Bet app
- Tone: direct, technical (Jerome has 20+ years dev experience)
- Show competency distribution, learning velocity, gaps
- Flag concerns proactively (long inactivity, stuck on a topic, regression)

### Engagement Monitor

```toml
name = "engagement-monitor"
version = "1.0.0"
description = "Lightweight inactivity checker — nudges William when idle"
author = "jerome"
module = "builtin:chat"
tags = ["monitoring", "engagement"]

[model]
provider = "anthropic"
model = "claude-haiku-4-5-20251001"

[schedule]
periodic = { cron = "0 16,19 * * *" }

[resources]
max_llm_tokens_per_hour = 5000
max_iterations = 3

[capabilities]
tools = ["memory_recall", "agent_send"]
memory_read = ["shared.progress"]
memory_write = ["self.*"]
agent_message = ["tutor"]
```

**System prompt (complete — intentionally minimal):**
```
Read shared.progress.last_active.
If inactive > 48h AND current time is between 16h-21h Brussels:
  Send ONE short engaging message to the tutor agent to forward to William.
  Make it curiosity-driven, reference the World Cup Bet project.
  Never guilt-trip. Max 2 sentences.
If active within 48h: do nothing. Exit.
Max 1 nudge per 48h.
```

## Telegram Channel Config

```toml
[channels.telegram]
bot_token_env = "TELEGRAM_BOT_TOKEN"
allowed_users = ["8685378493", "8233154700"]

# Per-user routing — verify exact syntax against OpenFang docs at implementation time.
# If not natively supported, implement via channel overrides or a thin routing agent.
[channels.telegram.routing]
"8685378493" = "tutor"
"8233154700" = "parent"

[channels.telegram.overrides]
output_format = "telegram_html"
dm_policy = "allowed_only"
rate_limit_per_user = 10
```

## Cost Controls

```toml
# Global budget (via API after startup)
# PUT /api/budget { "budget_limit": 30.00 }
```

Per-agent token budgets (in manifests):
- tutor: 100k tokens/hour
- parent: 50k tokens/hour
- engagement-monitor: 5k tokens/hour

**Estimated daily cost:**

| Agent | Est. cost/day |
|---|---|
| tutor (2-3 sessions) | $0.50-1.50 |
| parent (1-2 interactions) | $0.10-0.30 |
| engagement-monitor (2 cron runs) | $0.02 |
| **Total** | **$0.60-1.80** |

vs nanobot: **~$27/day**

## Deployment

### Docker setup

Replace nanobot container with OpenFang. Keep backup sidecar unchanged.

```yaml
services:
  openfang:
    container_name: world-cup-bet-coach
    image: ghcr.io/rightnow-ai/openfang:latest  # or build from source
    restart: unless-stopped
    env_file: .env
    volumes:
      - world-cup-bet-data:/data
    ports:
      - "3000:3000"  # API for budget monitoring

  backup:
    container_name: world-cup-bet-backup
    build: { context: ., dockerfile: Dockerfile.backup }
    restart: unless-stopped
    env_file: .env
    volumes:
      - world-cup-bet-data:/data:ro

volumes:
  world-cup-bet-data:
    external: true
```

### Environment variables (.env)

```
ANTHROPIC_API_KEY=sk-ant-...
TELEGRAM_BOT_TOKEN=8756430869:AAH...
BACKUP_ENCRYPTION_KEY=...
```

### Project structure

```
world-cup-bet-coach/
├── openfang.toml              # Project config (providers, channels)
├── agents/
│   ├── tutor.toml             # Tutor agent manifest
│   ├── parent.toml            # Parent agent manifest
│   └── engagement-monitor.toml # Engagement monitor manifest
├── skills/
│   └── curriculum.json        # Static competency reference (35 skills)
├── prompts/
│   ├── tutor-system.md        # Tutor system prompt (from SOUL.md + AGENTS.md)
│   ├── parent-system.md       # Parent system prompt
│   └── engagement-system.md   # Engagement monitor prompt
├── docker-compose.yml
├── Dockerfile.backup
├── .env
└── docs/
```

## Data Migration

### From nanobot to OpenFang KV store

1. **progress.json** -> seed `shared.progress` and `shared.competencies`
   - Split current monolithic JSON into two focused KV entries
   - `shared.progress`: xp (40), level ("Debutant"), last_active ("2026-03-30"), daily_streak (0)
   - `shared.competencies`: the competencies map (vscode_codespaces, git_basics, deployment_basics, vercel_railway — all at "discovered")

2. **MEMORY.md** -> seed `shared.learning_style`
   - Extract observations about William's learning patterns
   - Currently sparse — will be enriched by tutor agent over time

3. **curriculum.json** -> keep as static file in `skills/`
   - 6 domains, ~35 competencies with level targets and discovery hooks
   - Tutor reads via `file_read`, not KV store (it's reference data, not mutable state)

4. **Jerome's initial curriculum** -> seed `shared.curriculum`
   - Create initial week plan and priority domains based on current state
   - Jerome can update anytime via parent agent

5. **World Cup Bet goals** -> seed `shared.goals`
   - Define initial milestones for the app (auth, match data, betting logic, UI, deployment)

### Files that don't migrate

- `SOUL.md` -> folded into tutor system prompt (`prompts/tutor-system.md`)
- `AGENTS.md` -> split across agent system prompts
- `USER.md` -> encoded in Telegram routing config + agent prompts
- `HEARTBEAT.md` -> replaced by engagement-monitor agent
- `TOOLS.md` -> replaced by OpenFang capability grants
- nanobot skills (clawbot-tutor, clawbot-quiz) -> folded into tutor system prompt

## Cutover Plan

1. Build OpenFang project structure alongside existing nanobot
2. Write agent manifests and system prompts
3. Create data migration script (progress.json -> KV seed)
4. Test with a separate Telegram bot token (create test bot via @BotFather)
5. Test full flow: William message -> tutor responds with context, Jerome message -> parent responds with report
6. Verify engagement-monitor fires correctly on schedule
7. Stop nanobot container
8. Switch to production bot token
9. Start OpenFang container
10. Verify with live messages from both users
11. Set global budget limit via API
12. Monitor costs for first 48h via `GET /api/budget/agents`
