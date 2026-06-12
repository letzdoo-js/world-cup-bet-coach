# World Cup Bet Coach — OpenFang Deployment Guide

## Architecture

3 agents communiquant via un KV store partagé (SQLite) :

| Agent | Modèle | Rôle | Parle à |
|-------|--------|------|---------|
| **leandro** | Claude Sonnet | Coach coding pour William (14 ans) | William via Telegram |
| **magnus** | Claude Sonnet | Interface parent pour Jerome | Jerome via Telegram |
| **engagement-monitor** | Claude Haiku | Moniteur d'inactivité (toutes les 6h) | leandro + magnus via agent_send |

### Routage Telegram

Le routage se fait via les **bindings** OpenFang (pas d'agent routeur LLM — zero token) :
- User ID `8685378493` (William) → leandro
- User ID `8233154700` (Jerome) → magnus

```toml
[[bindings]]
agent = "leandro"
[bindings.match_rule]
channel = "telegram"
peer_id = "8685378493"

[[bindings]]
agent = "magnus"
[bindings.match_rule]
channel = "telegram"
peer_id = "8233154700"
```

## Stack technique

- **OpenFang** : Agent OS en Rust, build from source (fork letzdoo-js/world-cup-coach-openfang)
- **Docker** : Image custom buildée depuis le submodule `openfang/`
- **Anthropic API** : Claude Sonnet + Haiku
- **Telegram Bot** : @world_cup_bet_coach_bot, polling mode
- **SQLite** : KV store pour la mémoire partagée entre agents

## Fichiers clés

```
world-cup-bet-coach/
├── openfang.toml              # Référence (la vraie config est dans le volume Docker)
├── agents/
│   ├── tutor.toml             # Manifest leandro (system prompt inclus inline)
│   ├── parent.toml            # Manifest magnus (system prompt inclus inline)
│   └── engagement-monitor.toml
├── prompts/                   # Prompts de référence (pas utilisés directement)
├── skills/
│   └── curriculum.json        # 35 compétences, 6 domaines
├── scripts/
│   ├── entrypoint.sh          # Clone repo + symlinks + openfang start --yolo
│   └── seed-kv.sh             # Migration données nanobot → KV (à adapter)
├── openfang/                  # Submodule : fork OpenFang (build from source)
│   └── deploy/
│       ├── entrypoint.sh      # Copié dans l'image Docker
│       └── deploy-key         # Clé SSH pour cloner world-cup-bet (read-only)
├── docker-compose.yml
└── .env                       # ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, BACKUP_ENCRYPTION_KEY
```

## Configuration OpenFang

La config réelle est dans le volume Docker (`/app/config.toml`). Points importants :

```toml
api_listen = "0.0.0.0:4200"

[default_model]
provider = "anthropic"
model = "claude-sonnet-4-20250514"
api_key_env = "ANTHROPIC_API_KEY"

[exec_policy]
mode = "unrestricted"          # Nécessaire pour shell_exec (git, rg, grep)

[channels.telegram]
bot_token_env = "TELEGRAM_BOT_TOKEN"
allowed_users = ["8685378493", "8233154700"]
```

## Leçons apprises (pièges OpenFang)

### System prompts inline dans le TOML
Les fichiers `prompts/*.md` ne sont PAS chargés automatiquement. Le system prompt doit être **inline** dans le `[model]` du manifest TOML :
```toml
[model]
system_prompt = """Le prompt ici..."""
```

### Pas de routage per-user natif
OpenFang ne supporte que `default_agent` par channel. Le routage par user ID se fait via les **bindings** (config `[[bindings]]` avec `match_rule.peer_id`).

### Workspaces isolés
Chaque agent a son propre workspace (`/app/workspaces/<agent_name>/`). Un agent ne peut PAS lire en dehors de son workspace. Les symlinks vers l'extérieur sont aussi bloqués.
**Solution** : copier le repo dans chaque workspace d'agent au démarrage (dans `entrypoint.sh`).

### exec_policy
Par défaut c'est `Allowlist` — les commandes shell sont restreintes. Il faut `mode = "unrestricted"` dans `[exec_policy]` de `config.toml` pour autoriser git, rg, grep, etc.
Les valeurs possibles : `deny`, `allowlist`, `unrestricted` (pas `yolo`).

### VOLUME Docker
Le Dockerfile OpenFang déclare `VOLUME /data`. Ça empêche les bind mounts sur `/data`. 
**Solution** : utiliser `OPENFANG_HOME=/app` et un named volume sur `/app`.

### Agents persistés avec ancien état
Quand on re-spawn un agent, il garde l'ancien system prompt en cache si on ne kill+spawn pas. Après un changement de manifest :
1. `openfang agent kill <id>`
2. `docker cp` du nouveau manifest
3. `openfang agent spawn /app/agents/<manifest>.toml`
4. Re-seed le KV si nécessaire

### Session stale
Si un agent a répondu avec des erreurs, le contexte de conversation garde ces erreurs. Il faut **reset la session** :
```bash
curl -X POST http://127.0.0.1:4200/api/agents/<id>/session/reset
```
Ou via python dans le container :
```bash
docker exec world-cup-bet-coach python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:4200/api/agents/<id>/session/reset', method='POST', data=b'{}'))"
```

### KV lié aux agent IDs
Le KV store est per-agent. Quand on kill+re-spawn un agent (nouvel ID), il faut re-seeder le KV :
```bash
docker exec world-cup-bet-coach openfang memory set <agent_name> <key> '<json>'
```

## Compaction automatique

OpenFang compacte automatiquement les sessions :
- Seuil : 30 messages → résumé LLM des anciens, garde les 10 derniers
- Seuil tokens : 70% de la fenêtre contexte (200k tokens)
- Pas besoin de configurer — actif par défaut

## Engagement monitor

Tourne toutes les 6h (`continuous = { check_interval_secs = 21600 }`). 3 checks :

1. **17h Bruxelles (15h UTC)** : nudge William via leandro
2. **Inactivité >96h** : alerte Jerome via magnus (puis toutes les 24h)
3. **7h Dubai (3h UTC)** : rapport d'activité à Jerome si William a été actif

## Commandes utiles

```bash
# Voir les agents
docker exec world-cup-bet-coach openfang agent list

# Budget / coûts
docker exec world-cup-bet-coach python3 -c "import urllib.request, json; print(json.dumps(json.loads(urllib.request.urlopen('http://127.0.0.1:4200/api/budget/agents').read()), indent=2))"

# Reset session d'un agent
docker exec world-cup-bet-coach python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:4200/api/agents/<id>/session/reset', method='POST', data=b'{}'))"

# Lire la mémoire d'un agent
docker exec world-cup-bet-coach openfang memory list <agent_name>

# Écrire dans le KV
docker exec world-cup-bet-coach openfang memory set <agent_name> <key> '<json_value>'

# Tester un agent via API
docker exec world-cup-bet-coach python3 -c "
import urllib.request, json
data = json.dumps({'message': 'ton message'}).encode()
req = urllib.request.Request('http://127.0.0.1:4200/api/agents/<id>/message', data=data, headers={'Content-Type': 'application/json'})
print(json.loads(urllib.request.urlopen(req, timeout=60).read().decode())['response'])
"

# Logs
docker logs world-cup-bet-coach --since 5m
docker logs world-cup-bet-coach -f  # follow

# Rebuild après changement Dockerfile/submodule
docker compose down && docker compose build coach && docker compose up coach -d
```

## Coûts estimés

| Agent | Coût/jour estimé |
|-------|-----------------|
| leandro (2-3 sessions) | $0.50-1.50 |
| magnus (1-2 interactions) | $0.10-0.30 |
| engagement-monitor (4x/jour) | $0.02 |
| **Total** | **~$0.60-1.80** |

vs nanobot : ~$27/jour
