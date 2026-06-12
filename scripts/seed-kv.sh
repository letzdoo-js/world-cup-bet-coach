#!/usr/bin/env bash
set -euo pipefail

# Seed OpenFang shared KV store from nanobot data
# Run once after first OpenFang start: docker exec world-cup-bet-coach sh /app/scripts/seed-kv.sh
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
