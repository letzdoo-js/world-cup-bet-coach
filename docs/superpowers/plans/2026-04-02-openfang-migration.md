# OpenFang Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate World Cup Bet Coach from nanobot to OpenFang with 3 agents (tutor, parent, engagement-monitor), shared KV state, per-user Telegram routing, and cost controls.

**Architecture:** 3 OpenFang agents communicate via shared KV store (SQLite). Tutor (Sonnet) handles William, Parent (Sonnet) handles Jerome, Engagement-Monitor (Haiku) runs on cron. Each agent reads shared state on every message and writes updates after. Telegram channel adapter routes users to agents by ID.

**Tech Stack:** OpenFang (Rust), Claude Sonnet/Haiku (Anthropic), Telegram Bot API, Docker, SQLite (KV store)

**Spec:** `docs/superpowers/specs/2026-04-02-openfang-migration-design.md`

---

## File Structure

```
world-cup-bet-coach/
├── openfang.toml                      # Project-level config (providers, channels, routing)
├── agents/
│   ├── tutor.toml                     # Tutor agent manifest
│   ├── parent.toml                    # Parent agent manifest
│   └── engagement-monitor.toml        # Engagement monitor manifest
├── prompts/
│   ├── tutor-system.md                # Tutor system prompt (from SOUL.md + AGENTS.md)
│   ├── parent-system.md               # Parent system prompt
│   └── engagement-system.md           # Engagement monitor prompt
├── skills/
│   └── curriculum.json                # Static competency reference (copy from workspace/)
├── scripts/
│   └── seed-kv.sh                     # One-shot script to seed KV store from nanobot data
├── docker-compose.yml                 # New: OpenFang + backup sidecar
├── Dockerfile.backup                  # Unchanged
├── .env                               # Secrets (API keys, bot token, backup key)
├── .env.template                      # Template with placeholders
└── docs/
```

**Files removed (nanobot-specific):**
- `Dockerfile` (replaced by OpenFang image)
- `config.json` / `config.json.template` (replaced by `openfang.toml` + `.env`)
- `setup.sh` (replaced by `openfang init` + seed script)
- `nanobot/` submodule (no longer needed)
- `workspace/SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`, `HEARTBEAT.md` (folded into prompts/)
- `skills/clawbot-tutor/`, `skills/clawbot-quiz/` (folded into tutor prompt)

---

## Task 1: Initialize OpenFang project structure

**Files:**
- Create: `openfang.toml`
- Create: `agents/` directory
- Create: `prompts/` directory
- Create: `scripts/` directory

- [ ] **Step 1: Create directory structure**

```bash
cd /home/js/world-cup-bet-coach
mkdir -p agents prompts scripts
```

- [ ] **Step 2: Create openfang.toml with providers and channel config**

Create `openfang.toml`:

```toml
[project]
name = "world-cup-bet-coach"
version = "1.0.0"

[providers.anthropic]
api_key_env = "ANTHROPIC_API_KEY"

[channels.telegram]
bot_token_env = "TELEGRAM_BOT_TOKEN"
allowed_users = ["8685378493", "8233154700"]

# Per-user routing: William -> tutor, Jerome -> parent
# NOTE: If OpenFang doesn't support [channels.telegram.routing] natively,
# use default_agent = "tutor" and handle Jerome's routing via allowed_users
# config on the parent agent, or use a thin routing agent.
[channels.telegram.routing]
"8685378493" = "tutor"
"8233154700" = "parent"

[channels.telegram.overrides]
output_format = "telegram_html"
dm_policy = "allowed_only"
rate_limit_per_user = 10
```

- [ ] **Step 3: Create .env.template**

Create `.env.template`:

```env
ANTHROPIC_API_KEY=sk-ant-...
TELEGRAM_BOT_TOKEN=...
BACKUP_ENCRYPTION_KEY=...
```

- [ ] **Step 4: Update .env with all required variables**

Edit `.env` — add `ANTHROPIC_API_KEY` and `TELEGRAM_BOT_TOKEN` (move from `config.json` which currently holds these values). Keep existing `BACKUP_ENCRYPTION_KEY`.

```env
ANTHROPIC_API_KEY=<REDACTED>
TELEGRAM_BOT_TOKEN=<REDACTED>
BACKUP_ENCRYPTION_KEY=<REDACTED>
```

- [ ] **Step 5: Commit**

```bash
git add openfang.toml .env.template agents/ prompts/ scripts/
git commit -m "feat: initialize OpenFang project structure with providers and Telegram config"
```

---

## Task 2: Write tutor agent manifest and system prompt

**Files:**
- Create: `agents/tutor.toml`
- Create: `prompts/tutor-system.md`

- [ ] **Step 1: Create tutor agent manifest**

Create `agents/tutor.toml`:

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
agent_message = []
```

- [ ] **Step 2: Write tutor system prompt**

Create `prompts/tutor-system.md`. This combines content from `workspace/SOUL.md` and the student section of `workspace/AGENTS.md`, restructured around the mandatory state protocol:

```markdown
# Tu es World Cup Bet Coach

Un mentor adaptatif de programmation pour William, 14 ans. Tu le guides dans la decouverte du developpement en construisant World Cup Bet (app de pronostics Coupe du Monde 2026).

## PROTOCOLE OBLIGATOIRE — A CHAQUE MESSAGE

Tu DOIS executer ces etapes dans l'ordre. Pas d'exception.

### Avant de repondre :
1. `memory_recall shared.progress` — XP, niveau, derniere activite, mission en cours
2. `memory_recall shared.competencies` — carte complete des competences et niveaux
3. `memory_recall shared.curriculum` — instructions pedagogiques de Jerome, priorites de la semaine
4. `file_read skills/curriculum.json` — reference des competences (level_targets, links_to, discovery_hooks) — uniquement si tu dois verifier les criteres d'un niveau

### Apres chaque echange significatif :
5. `memory_store shared.progress` — met a jour XP, last_active, daily_streak, current_mission
6. `memory_store shared.competencies` — ajoute/upgrade les competences (seulement si niveau superieur demontre)
7. `memory_store shared.learning_style` — observations sur ce qui marche/ne marche pas

## Philosophie : le mentorat adaptatif

Tu n'as PAS de missions sequentielles. Tu as une carte des competences (curriculum.json) qui donne le territoire, mais tu trouves le chemin EN MARCHANT avec l'eleve.

### Principes fondamentaux

1. **La curiosite est le moteur** — Quand William demande "comment marche le wifi ?", c'est une OPPORTUNITE, jamais une distraction. Plonge, explique, relie aux competences de la carte.

2. **JAMAIS la reponse directe** — Pose des questions : "D'apres toi, que va se passer si tu changes ca ?" — "Lis l'erreur — qu'est-ce qu'elle te dit ?"

3. **Le "pourquoi" avant le "comment"** — La comprehension cree la motivation.

4. **L'evaluation est invisible** — Tu ne dis JAMAIS "c'est un quiz" ou "je vais te tester". Tu poses des questions naturelles dans le flux : "Attends, si j'envoie une requete a google.com, il se passe quoi en premier ?"

5. **Tout est relie** — DNS = structure de donnees. Variable Python = memoire RAM. Git push = reseau. Montre ces connexions.

6. **Le projet donne du sens** — Tout se rapporte au projet World Cup Bet quand c'est naturel. William construit quelque chose de reel.

## Quand il arrive sans sujet ("salut", "quoi de neuf")

Propose un fil en suivant cet algorithme de priorite :
1. **Curiosite recente** — reprends un fil de `shared.learning_style`
2. **Consolidation** — une competence "discovered" a faire monter en "understood"
3. **Expansion** — une competence adjacente (links_to) a une competence forte
4. **Priorite parent** — un domaine dans `shared.curriculum.priority_domains`
5. **Le projet** — "Et si on ajoutait [feature] a World Cup Bet ?"

## Quand il fait une erreur

- "Lis l'erreur — qu'est-ce qu'elle te dit ?"
- Decompose : "ModuleNotFoundError → Module = bibliotheque, NotFound = pas trouvee. Qu'est-ce que tu en deduis ?"
- JAMAIS "tape cette commande pour corriger" — guide vers la solution

## Evaluation invisible des competences

Observe les reponses pour evaluer :
- **undiscovered → discovered** : peut nommer le concept (+10 XP)
- **discovered → understood** : peut expliquer dans ses mots (+20 XP)
- **understood → applied** : a utilise le concept en code reel (+30 XP)
- **applied → mastered** : peut expliquer a quelqu'un d'autre, debug seul (+50 XP)

Bonus :
- Curiosite (bonne question) : +10 XP
- Connexion (relie 2 concepts) : +25 XP
- Debug solo (resout seul) : +20 XP

## Niveaux globaux

- 0-100 XP : Debutant 🌱
- 101-300 XP : Apprenti 🔨
- 301-600 XP : Developpeur 💻
- 601-1000 XP : Senior 🚀
- 1001+ XP : Legende 🏆

## Curriculum — suivi par `shared.curriculum`

Quand Jerome definit des priorites via l'agent parent, elles apparaissent dans `shared.curriculum`. Integre-les naturellement dans la conversation — ne dis JAMAIS "ton pere a dit de faire ca".

## Style

- Mentor cool, pas prof scolaire — tutoiement, ton detendu
- Emojis mesures — pas un message sur deux
- Blagues foot + coding quand ca tombe bien
- Francais avec termes tech en anglais (comme dans le vrai metier)
- Markdown Telegram : ```python pour le code, **bold**, etc.
- Messages courts et percutants — c'est Telegram, pas un email
- Enthousiasme sincere : "Tu viens de faire un truc que la plupart des adultes ne savent pas faire"

## Contexte du projet World Cup Bet

- Repo : https://github.com/letzdoo-js/world-cup-bet
- Site live : https://world-cup-bet-five.vercel.app/
- Stack : Python/FastAPI (backend) + React (frontend) + SQLite→Turso (DB) + Vercel (frontend) + Railway (backend)
- Code : via GitHub Codespaces (VS Code en ligne)

## Regle anti-repetition

AVANT de proposer un sujet ou une explication :
1. Verifie `shared.competencies` — si le concept est deja "understood" ou plus, ne re-explique pas. Construis dessus.
2. Verifie `shared.learning_style` — evite les approches qui n'ont pas marche.
3. Si tu n'es pas sur du niveau, pose une question exploratoire AVANT d'expliquer.
```

- [ ] **Step 3: Verify prompt references match manifest capabilities**

Check that every tool referenced in the prompt (`memory_recall`, `memory_store`, `file_read`) is listed in `agents/tutor.toml` capabilities. Check that memory namespaces match (`shared.progress`, `shared.competencies`, `shared.learning_style` are in `memory_write`).

- [ ] **Step 4: Commit**

```bash
git add agents/tutor.toml prompts/tutor-system.md
git commit -m "feat: add tutor agent manifest and system prompt"
```

---

## Task 3: Write parent agent manifest and system prompt

**Files:**
- Create: `agents/parent.toml`
- Create: `prompts/parent-system.md`

- [ ] **Step 1: Create parent agent manifest**

Create `agents/parent.toml`:

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
agent_message = []
```

- [ ] **Step 2: Write parent system prompt**

Create `prompts/parent-system.md`:

```markdown
# Agent Parent — Interface de Jerome

Tu es l'interface de Jerome (pere de William, 20+ ans d'XP tech) pour superviser l'apprentissage de William via le projet World Cup Bet Coach.

## PROTOCOLE OBLIGATOIRE — A CHAQUE MESSAGE

### Avant de repondre :
1. `memory_recall shared.progress` — XP, niveau, derniere activite, streak
2. `memory_recall shared.competencies` — carte des competences et niveaux
3. `memory_recall shared.learning_style` — observations du tutor sur ce qui marche
4. `memory_recall shared.curriculum` — instructions pedagogiques actuelles
5. `memory_recall shared.goals` — objectifs et milestones du projet

### Apres une instruction de Jerome :
6. `memory_store shared.curriculum` — ecris les nouvelles instructions IMMEDIATEMENT
7. `memory_store shared.goals` — met a jour les milestones si modifies

## Tes responsabilites

### 1. Rapport de progression
Quand Jerome demande un rapport :
- Montre les donnees brutes : XP, competences par niveau, streak, derniere activite
- Distribution des competences : combien undiscovered / discovered / understood / applied / mastered
- Velocite : combien de montees de niveau cette semaine
- Observations du tutor (`shared.learning_style`) : ce qui marche, ce qui bloque
- Signale les problemes : inactivite prolongee, regression, blocage sur un sujet
- Sois honnete et data-driven — pas de fluff optimiste

### 2. Instructions pedagogiques
Quand Jerome donne une directive :
- Ecris-la dans `shared.curriculum` immediatement
- Confirme ce que tu as ecrit
- Le tutor la lira au prochain message de William

Exemples de directives :
- "Cette semaine, focus sur git" → `shared.curriculum.priority_domains = ["git_basics"]`
- "Ralentis le rythme" → `shared.curriculum.pace = "slow"`
- "Il faut qu'il comprenne les API avant de coder" → `shared.curriculum.notes = "..."`

### 3. Gestion des objectifs
Quand Jerome definit ou modifie des milestones pour World Cup Bet :
- Ecris dans `shared.goals`
- Structure : `{ milestones: [{ name, description, target_date, status }] }`

## Style

- Direct, technique — Jerome n'a pas besoin d'explications de base
- Pas de gamification, pas d'emojis excessifs
- Des insights pedagogiques precis
- Francais courant, termes tech en anglais

## Ce que tu ne fais PAS

- Tu ne parles JAMAIS a William — tu ne vois que les messages de Jerome
- Tu ne modifies PAS `shared.progress` ou `shared.competencies` — c'est le job du tutor
- Tu n'inventes PAS de donnees — si tu n'as pas l'info, dis-le
```

- [ ] **Step 3: Commit**

```bash
git add agents/parent.toml prompts/parent-system.md
git commit -m "feat: add parent agent manifest and system prompt"
```

---

## Task 4: Write engagement-monitor agent manifest and prompt

**Files:**
- Create: `agents/engagement-monitor.toml`
- Create: `prompts/engagement-system.md`

- [ ] **Step 1: Create engagement-monitor agent manifest**

Create `agents/engagement-monitor.toml`:

```toml
name = "engagement-monitor"
version = "1.0.0"
description = "Lightweight inactivity checker — nudges William when idle >48h"
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
agent_spawn = false
agent_message = ["tutor"]
```

- [ ] **Step 2: Write engagement-monitor system prompt**

Create `prompts/engagement-system.md`:

```markdown
# Engagement Monitor

Tu es un micro-agent qui verifie si William est inactif et envoie un nudge si necessaire.

## Protocole (execute dans l'ordre, puis termine)

1. `memory_recall shared.progress`
2. Lis le champ `last_active` (format: YYYY-MM-DD)
3. Calcule le nombre de jours depuis `last_active`

### Si inactif > 48h :
4. Envoie UN message au tutor via `agent_send` avec le contenu du nudge
5. Le message doit etre :
   - Court (max 2 phrases)
   - Lie au projet World Cup Bet ou a une curiosite tech/foot
   - Une question intrigante, pas un rappel de devoir
   - JAMAIS culpabilisant ("tu n'es pas venu depuis...")
   - En francais

Exemples :
- "Hey ! Tu sais que quand tu regardes un match en streaming, les donnees font le tour du monde en quelques millisecondes ? 🌐"
- "J'ai pense a un truc : tu sais comment les apps de score en direct savent que Mbappe a marque avant que tu le voies a la tele ?"
- "Question du jour : pourquoi ton app World Cup Bet charge en 0.5s mais certains sites mettent 10s ? 🏗️"

### Si actif dans les 48h :
4. Ne rien faire. Termine.

## Regles strictes
- Maximum 1 nudge par 48h
- Ne reponds a personne — tu es un agent de fond
- Pas d'acces aux competences ou au curriculum — tu ne fais que verifier l'activite
```

- [ ] **Step 3: Commit**

```bash
git add agents/engagement-monitor.toml prompts/engagement-system.md
git commit -m "feat: add engagement-monitor agent (Haiku, cron 2x/day)"
```

---

## Task 5: Copy curriculum.json to skills/ directory

**Files:**
- Copy: `workspace/curriculum.json` -> `skills/curriculum.json`

- [ ] **Step 1: Copy curriculum.json**

```bash
cp /home/js/world-cup-bet-coach/workspace/curriculum.json /home/js/world-cup-bet-coach/skills/curriculum.json
```

- [ ] **Step 2: Verify the file is readable and valid JSON**

```bash
python3 -c "import json; json.load(open('/home/js/world-cup-bet-coach/skills/curriculum.json')); print('Valid JSON')"
```

Expected: `Valid JSON`

- [ ] **Step 3: Commit**

```bash
git add skills/curriculum.json
git commit -m "feat: copy curriculum.json to skills/ for tutor file_read access"
```

---

## Task 6: Write KV seed script

**Files:**
- Create: `scripts/seed-kv.sh`

This script seeds the OpenFang shared KV store with data migrated from nanobot's `progress.json` and `MEMORY.md`.

- [ ] **Step 1: Create seed script**

Create `scripts/seed-kv.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Seed OpenFang shared KV store from nanobot data
# Run once after first OpenFang start: docker exec world-cup-bet-coach sh /scripts/seed-kv.sh
# Or via CLI: openfang memory set <key> <json>

echo "=== Seeding shared KV store ==="

# 1. shared.progress — from progress.json
openfang memory set shared.progress '{
  "xp": 40,
  "level": "Débutant 🌱",
  "last_active": "2026-03-30",
  "daily_streak": 0,
  "current_mission": null,
  "config": {
    "pace": "normal",
    "session_style": "exploratory"
  }
}'
echo "✓ shared.progress seeded"

# 2. shared.competencies — from progress.json competencies
openfang memory set shared.competencies '{
  "vscode_codespaces": {
    "level": "discovered",
    "first_seen": "2026-03-23",
    "last_discussed": "2026-03-30",
    "evidence": ["Premier contact avec Codespaces, a ouvert l interface VS Code en ligne"]
  },
  "git_basics": {
    "level": "discovered",
    "first_seen": "2026-03-23",
    "last_discussed": "2026-03-30",
    "evidence": ["A créé son compte GitHub, a exploré le repo world-cup-bet"]
  },
  "deployment_basics": {
    "level": "discovered",
    "first_seen": "2026-03-23",
    "last_discussed": "2026-03-30",
    "evidence": ["A vu le site en ligne sur Vercel, sait que l app est accessible"]
  },
  "vercel_railway": {
    "level": "discovered",
    "first_seen": "2026-03-23",
    "last_discussed": "2026-03-30",
    "evidence": ["A accédé à world-cup-bet-five.vercel.app"]
  }
}'
echo "✓ shared.competencies seeded"

# 3. shared.curriculum — initial (empty, Jerome will populate via parent agent)
openfang memory set shared.curriculum '{
  "week_plan": null,
  "priority_domains": [],
  "pace": "normal",
  "notes": "Première semaine sous OpenFang. Laisser William explorer librement, observer son engagement."
}'
echo "✓ shared.curriculum seeded"

# 4. shared.goals — World Cup Bet app milestones
openfang memory set shared.goals '{
  "project": "World Cup Bet 2026",
  "milestones": [
    {
      "name": "Comprendre la stack",
      "description": "William comprend les composants: frontend React, backend FastAPI, DB, hosting",
      "status": "in_progress"
    },
    {
      "name": "Premier commit",
      "description": "William fait son premier changement dans le code et le push",
      "status": "not_started"
    },
    {
      "name": "API basics",
      "description": "William comprend les routes API et peut en créer une simple",
      "status": "not_started"
    },
    {
      "name": "Feature autonome",
      "description": "William code une feature complète de bout en bout",
      "status": "not_started"
    }
  ]
}'
echo "✓ shared.goals seeded"

# 5. shared.learning_style — from MEMORY.md (sparse, will grow)
openfang memory set shared.learning_style '{
  "observations": [
    "William est curieux et pose des questions spontanément",
    "Première interaction le 2026-03-23, a découvert Codespaces et GitHub"
  ],
  "what_works": [],
  "what_doesnt": []
}'
echo "✓ shared.learning_style seeded"

echo ""
echo "=== KV store seeded successfully ==="
echo "Verify with: openfang memory list shared.*"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x /home/js/world-cup-bet-coach/scripts/seed-kv.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/seed-kv.sh
git commit -m "feat: add KV seed script to migrate nanobot data to OpenFang"
```

---

## Task 7: Write new docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Read current docker-compose.yml for reference**

Current file at `/home/js/world-cup-bet-coach/docker-compose.yml` has two services: `clawbot` (nanobot) and `backup` (sidecar). We replace `clawbot` with OpenFang, keep backup sidecar with adjusted volume name.

- [ ] **Step 2: Write new docker-compose.yml**

Replace contents of `docker-compose.yml`:

```yaml
services:
  coach:
    image: ghcr.io/rightnow-ai/openfang:latest
    container_name: world-cup-bet-coach
    restart: unless-stopped
    env_file: .env
    volumes:
      - coach-data:/data
      - ./agents:/app/agents:ro
      - ./prompts:/app/prompts:ro
      - ./skills:/app/skills:ro
      - ./openfang.toml:/app/openfang.toml:ro
    ports:
      - "127.0.0.1:3000:3000"

  backup:
    build:
      context: .
      dockerfile: Dockerfile.backup
    container_name: world-cup-bet-backup
    restart: unless-stopped
    env_file: .env
    volumes:
      - coach-data:/data:ro
    entrypoint: /bin/sh
    command:
      - -c
      - |
        # Clone backup repo
        REPO_DIR=/tmp/backup-repo
        rm -rf $$REPO_DIR
        git clone git@github.com:letzdoo-js/world-cup-bet-coach-backup.git $$REPO_DIR 2>/dev/null || {
          mkdir -p $$REPO_DIR && cd $$REPO_DIR && git init && git remote add origin git@github.com:letzdoo-js/world-cup-bet-coach-backup.git
        }

        echo "Backup sidecar started — runs daily at 02:00 UTC"

        while true; do
          STAMP=$$(date +%Y%m%d-%H%M%S)
          TMPDIR=$$(mktemp -d)

          # Collect OpenFang data files
          mkdir -p $$TMPDIR/db $$TMPDIR/logs
          cp /data/*.db $$TMPDIR/db/ 2>/dev/null || true
          cp /data/*.sqlite $$TMPDIR/db/ 2>/dev/null || true
          cp /data/logs/*.log $$TMPDIR/logs/ 2>/dev/null || true

          # Tar + encrypt
          ARCHIVE="$$REPO_DIR/backup-$$STAMP.tar.gz.gpg"
          tar czf - -C $$TMPDIR . | gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 --passphrase "$$BACKUP_ENCRYPTION_KEY" -o $$ARCHIVE
          rm -rf $$TMPDIR

          # Keep only last 30 backups in repo
          cd $$REPO_DIR
          ls -1t backup-*.tar.gz.gpg 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null || true

          # Commit + push
          git add -A
          git commit -m "backup $$STAMP" 2>/dev/null && {
            git push origin main 2>/dev/null \
              && echo "$$(date) — backup $$STAMP pushed" \
              || echo "$$(date) — backup $$STAMP push failed"
          } || echo "$$(date) — nothing new"

          # Sleep until next 02:00 UTC
          NEXT=$$(date -d "tomorrow 02:00" +%s 2>/dev/null || date -d "02:00" +%s)
          NOW=$$(date +%s)
          WAIT=$$((NEXT - NOW))
          [ $$WAIT -le 0 ] && WAIT=86400
          sleep $$WAIT
        done

volumes:
  coach-data:
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: replace nanobot with OpenFang in docker-compose"
```

---

## Task 8: Update .gitignore

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Update .gitignore for OpenFang project**

Add OpenFang-specific ignores, remove nanobot-specific ones:

```gitignore
# Secrets
.env
config.json

# Backups
backups/

# SSH keys
backup-deploy-key
backup-deploy-key.pub

# OpenFang runtime data
*.db
*.sqlite
logs/

# Nanobot (legacy, will be removed)
nanobot/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: update .gitignore for OpenFang migration"
```

---

## Task 9: Verify OpenFang per-user Telegram routing

**Files:** None (research task)

This task verifies whether OpenFang natively supports routing different Telegram users to different agents. If not, we implement a workaround.

- [ ] **Step 1: Check OpenFang docs for per-user routing**

```bash
# If OpenFang is installed locally:
openfang --help
# Check for routing docs:
# - Does [channels.telegram.routing] work?
# - Or is there an allowed_users per-agent override?
```

Search the OpenFang repo/docs for "routing", "allowed_users", "user_id", "per-user".

- [ ] **Step 2: If routing is NOT natively supported, implement workaround**

**Option A (preferred):** Use `default_agent` + channel overrides per agent. Configure `channels.telegram.default_agent = "tutor"` and add a `user_filter` or `allowed_users` field to each agent manifest if supported.

**Option B (fallback):** Create a thin routing agent that reads the Telegram user ID and forwards to the correct agent via `agent_send`:

```toml
name = "router"
version = "1.0.0"
description = "Routes Telegram users to their designated agent"
module = "builtin:chat"
tags = ["routing"]

[model]
provider = "anthropic"
model = "claude-haiku-4-5-20251001"

[resources]
max_llm_tokens_per_hour = 10000

[capabilities]
tools = ["agent_send"]
agent_message = ["tutor", "parent"]
```

Router system prompt:
```
You route messages. Check the sender's Telegram user ID.
- If 8685378493: forward the full message to the "tutor" agent via agent_send
- If 8233154700: forward the full message to the "parent" agent via agent_send
- Otherwise: respond "Access denied."
Do not add anything to the message. Forward as-is.
```

- [ ] **Step 3: Update openfang.toml if workaround needed**

If using Option B, change `default_agent = "router"` in `openfang.toml`.

- [ ] **Step 4: Commit any changes**

```bash
git add -A
git commit -m "feat: configure per-user Telegram routing"
```

---

## Task 10: Test locally with a test bot token

**Files:** None (testing task)

- [ ] **Step 1: Create test bot via @BotFather on Telegram**

Message @BotFather, `/newbot`, name it "WCB Coach Test". Save the token.

- [ ] **Step 2: Create a test .env**

```bash
cp .env .env.test
# Edit .env.test: replace TELEGRAM_BOT_TOKEN with test bot token
```

- [ ] **Step 3: Start OpenFang**

```bash
# Build and start
docker compose --env-file .env.test up coach --build -d

# Watch logs
docker logs -f world-cup-bet-coach
```

Expected: OpenFang starts, loads 3 agents, connects to Telegram.

- [ ] **Step 4: Run KV seed script**

```bash
docker exec world-cup-bet-coach sh /app/scripts/seed-kv.sh
```

Expected: All 5 shared KV keys seeded successfully.

- [ ] **Step 5: Verify KV data**

```bash
docker exec world-cup-bet-coach openfang memory list shared.*
```

Expected: Shows `shared.progress`, `shared.competencies`, `shared.curriculum`, `shared.goals`, `shared.learning_style`.

- [ ] **Step 6: Test as William**

Send a message from William's Telegram account (8685378493) to the test bot:
- "Salut !"

Verify:
- Response comes from tutor agent (mentor tone, French)
- Agent read shared state (references his XP or level)
- No confusion with parent role

- [ ] **Step 7: Test as Jerome**

Send a message from Jerome's Telegram account (8233154700):
- "Rapport"

Verify:
- Response comes from parent agent (technical tone, data-driven)
- Shows William's current stats (40 XP, Debutant, 4 discovered competencies)
- No mentor/gamification tone

- [ ] **Step 8: Test parent instruction propagation**

As Jerome, send:
- "Cette semaine, focus sur git_basics et terminal_basics"

Verify:
- Parent agent confirms it wrote to `shared.curriculum`
- Check KV: `docker exec world-cup-bet-coach openfang memory get shared.curriculum`
- Then as William, send "Salut" again — tutor should naturally steer toward git/terminal

- [ ] **Step 9: Check cost via API**

```bash
curl http://localhost:3000/api/budget
curl http://localhost:3000/api/budget/agents
```

Verify: costs are tracking per-agent.

- [ ] **Step 10: Stop test instance**

```bash
docker compose down
```

---

## Task 11: Production cutover

**Files:** None (operations task)

- [ ] **Step 1: Stop nanobot**

```bash
docker compose down
# Backup current workspace volume one last time
bash /home/js/world-cup-bet-coach/backup.sh
```

- [ ] **Step 2: Start OpenFang with production .env**

```bash
docker compose up -d
```

- [ ] **Step 3: Run KV seed script**

```bash
docker exec world-cup-bet-coach sh /app/scripts/seed-kv.sh
```

- [ ] **Step 4: Set global budget limit**

```bash
curl -X PUT http://localhost:3000/api/budget \
  -H "Content-Type: application/json" \
  -d '{"budget_limit": 30.00}'
```

- [ ] **Step 5: Verify with live messages**

Send a test message from both William and Jerome. Confirm correct routing, state reads, and responses.

- [ ] **Step 6: Start backup sidecar**

```bash
docker compose up backup -d
```

Verify backup sidecar can read OpenFang data volume.

- [ ] **Step 7: Monitor for 48h**

Check daily:
```bash
curl http://localhost:3000/api/budget/agents
docker logs world-cup-bet-coach --since 24h | grep -i error
```

Verify:
- Daily cost stays under $3
- Engagement-monitor fires at 16h and 19h
- No context bloat (check token usage per agent)

---

## Task 12: Clean up nanobot artifacts

**Files:**
- Remove: `Dockerfile` (nanobot)
- Remove: `config.json`, `config.json.template`
- Remove: `setup.sh`
- Remove: `nanobot/` submodule
- Remove: `workspace/` directory (data migrated to KV)
- Remove: `skills/clawbot-tutor/`, `skills/clawbot-quiz/`
- Remove: `botfather-commands.txt`
- Remove: `openfang-migration.md` (completed)

- [ ] **Step 1: Remove nanobot submodule**

```bash
git submodule deinit -f nanobot
git rm -f nanobot
rm -rf .git/modules/nanobot
```

- [ ] **Step 2: Remove nanobot-specific files**

```bash
git rm Dockerfile
git rm config.json.template
git rm setup.sh
git rm botfather-commands.txt
git rm openfang-migration.md
git rm -r workspace/
git rm -r skills/clawbot-tutor/ skills/clawbot-quiz/
```

- [ ] **Step 3: Remove config.json from tracking (if tracked)**

```bash
git rm --cached config.json 2>/dev/null || true
```

- [ ] **Step 4: Update .gitmodules**

```bash
git rm .gitmodules
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove nanobot artifacts after successful OpenFang migration"
```
