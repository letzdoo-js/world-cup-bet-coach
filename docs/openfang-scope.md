# OpenFang — ce qu'il fait (vraiment) pour ce projet

But de ce doc : lister factuellement ce qu'openfang apporte au projet `world-cup-bet-coach`, ce qui marche, ce qui ne marche pas, et ce qu'un remplacement devrait fournir. Basé sur 6 semaines d'usage en prod (mars–avril 2026).

## 1. Contexte

- 1 container Docker `world-cup-bet-coach`, image `openfang v0.5.7` (fork `letzdoo-js/world-cup-coach-openfang`).
- 3 agents hébergés :
  - **leandro** — coach de code pour William (14 ans, zéro IT), Claude Sonnet 4.
  - **magnus** — interface de Jerome sur Telegram, Claude Haiku 4.5.
  - **engagement-monitor** — micro-agent cron (nudge William, rapport quotidien Jerome, alerte inactivité), Claude Haiku 4.5.
- État persistant dans SQLite `/app/data/openfang.db` (volume Docker).
- Pont Telegram intégré (chat_id Jerome + chat_id William).

## 2. Ce qu'openfang fournit et que nous utilisons

### 2.1 Agent loop
- Boucle LLM → tool call → tool result → LLM, avec budgets : `max_iterations`, `max_llm_tokens_per_hour`.
- Provider abstraction (ici Anthropic uniquement).
- Trimming automatique de la session quand le contexte dépasse un seuil (`Trimming old messages to prevent context overflow`).
- Heartbeat + auto-recovery quand un agent "crash" (agent marqué unresponsive après N secondes inactive).
- Sessions persistées (1 par agent) — reprises d'un run à l'autre.

### 2.2 Catalogue de tools
Appelables par les agents selon `capabilities.tools` dans le manifest :
- `file_read`, `file_list`, `apply_patch`, `file_write` — FS dans le workspace.
- `shell_exec` — shell avec whitelist par agent.
- `memory_store`, `memory_recall` — KV (`shared.*` namespace partagé + `self.*` par agent).
- `channel_send` — envoi sortant vers un canal (Telegram pour nous).
- `agent_send`, `agent_spawn`, `agent_list`, `agent_kill`, `agent_find` — messaging inter-agents.
- `web_search`, `web_fetch` — net (via provider configuré).
- `task_post`, `task_claim`, `task_complete`, `task_list` — queue de tâches inter-agents.
- `event_publish` — pub/sub (non utilisé ici).
- `knowledge_add_entity`, `knowledge_add_relation`, `knowledge_query` — graphe de connaissances (non utilisé).
- `schedule_create`, `schedule_list`, `schedule_delete` — **HALF-BAKED, voir §4**.
- `image_analyze`, `location_get`, `browser_*` — non utilisés.

### 2.3 Mémoire KV
- SQLite table `kv_store`, clés arbitraires, valeurs JSON.
- Permissions fines par agent via `memory_read` / `memory_write` (globs).
- Pour nous : `shared.progress`, `shared.competencies`, `shared.learning_style`, `shared.goals`, `shared.curriculum`.
- Persistance à travers les restarts.

### 2.4 Sessions (historique conversationnel)
- Table `sessions` — msgpack encodé, 1 entrée par agent (réutilisée à l'infini, pas de rotation).
- Messages trimmés automatiquement — pas d'historique long terme.

### 2.5 Cron scheduler (le vrai)
- `/app/cron_jobs.json` + `cron_scheduler` dans le kernel.
- Cron 5-champs, timezone optionnel.
- Action : envoyer un message texte à un agent, qui run son loop dessus.
- Utilisé pour : nudge William 15h UTC, rapport Jerome 03h UTC, alerte inactivité 00h/06h/12h UTC.
- Création via `POST /api/cron/jobs` (accessible en HTTP interne).

### 2.6 Bridge Telegram
- Long-polling Telegram → queue → input de l'agent cible (routing par chat_id → agent).
- `channel_send(channel="telegram", recipient="...")` → Telegram Bot API.
- Whitelist de chat_ids (sinon rejet).

### 2.7 API REST
Endpoints qu'on utilise réellement :
- `GET /api/agents` — liste (avec IDs, noms).
- `GET /api/agents/{id}` — manifest (sans `system_prompt`, cf §4).
- `PATCH /api/agents/{id}` — mise à jour hot du manifest (prompt, model, etc.) — **pas de restart**.
- `POST /api/cron/jobs` — créer un cron.
- `GET /api/cron/jobs` — lister.
- `DELETE /api/cron/jobs/{id}` — supprimer.
- `POST /api/skills/reload` — rescanner les skills installés.
- `POST /api/agents/{id}/messages` (ou équivalent) — envoyer un message à un agent (utilisé par `send.sh`).
- WebSocket `/ws` — streaming d'événements (non exploité côté scripts, mais dashboard UI l'utilise).

### 2.8 Dashboard UI (web)
- Page d'admin pour voir les agents, les crons, les logs, les coûts LLM. Port 4200 (non exposé par défaut — tunnel SSH pour y accéder).

## 3. Ce qui marche bien dans notre usage

- **Hot-reload du prompt** via `PATCH /api/agents/{id}` — pas de redémarrage, itération rapide.
- **Cron scheduler** — fiable une fois créé (sauf au restart, cf §4).
- **KV** — simple, rapide, persistant.
- **Tool routing** — stable.
- **Bridge Telegram** — pas de perte de message observée.
- **Usage tracking** — `usage_events` donne coût + tokens par appel LLM, utile pour budget.

## 4. Ce qui est cassé ou half-baked (gotchas réels rencontrés)

Documentation complète dans `docs/openfang-operations.md`. Résumé des écueils qui nous ont coûté du temps :

### 4.1 Cron wiped au restart (bug upstream — patché dans notre fork)
- Dans `activate_hand()` du kernel, `kill_agent()` appelle `remove_agent_jobs()` (wipe + persist `[]`) **avant** que `reassign_agent_jobs()` ait une chance de les migrer. Conséquence : chaque `docker restart` perdait les 3 crons d'EM.
- Fix : snapshot `Vec<CronJob>` avant kill, re-add après spawn. PR prête sur notre fork, non encore soumise upstream (`docs/openfang-cron-loss-issue.md`).

### 4.2 `schedule_create` tool ne fait rien
- Le tool LLM existe (`schedule_create`, `schedule_list`, `schedule_delete`), stocke les entrées dans `__openfang_schedules` KV, mais **aucun runner ne lit ce KV**. Les schedules créés par ce tool ne fire jamais.
- Deux systèmes parallèles (vrai `cron_scheduler` vs KV `__openfang_schedules`) sans bridge entre les deux.

### 4.3 `skills = ["_none_"]` au mauvais niveau
- 61 skills bundled injectés dans le prompt par défaut (~3k tokens de bruit). Pour les désactiver, il faut `skills = ["_none_"]` **au niveau root du manifest**, pas dans `[capabilities]` — l'erreur est silencieuse.

### 4.4 GET /api/agents/{id} ne renvoie pas `system_prompt`
- Champ omis de la réponse. Pour vérifier qu'un PATCH a pris, il faut lire SQLite directement (table `agents`, champ `manifest`, msgpack).

### 4.5 `/app` est un volume Docker, pas un bind-mount
- Éditer `agents/*.toml` sur l'host ne propage pas. Il faut soit `docker cp`, soit PATCH API, soit re-sync manuel. Les chemins nested (`/app/agents/leandro/agent.toml`) et flats (`/app/agents/tutor.toml`) existent tous les deux — faut écrire aux deux pour éviter les désyncs.

### 4.6 Agents chargés depuis SQLite, pas depuis .toml
- Au boot, openfang lit les `.toml`, calcule un diff, et met à jour SQLite. Ensuite la source de vérité est SQLite msgpack. Éditer un `.toml` après le boot ne change rien sans PATCH API.

### 4.7 Trimming session agressif
- Les messages anciens sont retirés sans alerte dès que le contexte approche la limite. Impossible de reconstituer l'historique d'une session de plus de 3–4 jours — les vieux messages ont été jetés.
- Table `events` existe dans le schéma mais est **vide en pratique** — pas d'event log fiable.

### 4.8 Pas de `curl` dans l'image
- L'image alpine-like n'a pas curl. Depuis le container il faut passer par Python urllib. Depuis l'host, passer par l'IP interne du container (port 4200 n'est pas publié).

### 4.9 Heredoc Python via `docker exec` silencieux
- `docker exec container python3 << 'EOF' ... EOF` ne rend pas le stdout visible. Toujours utiliser `python3 -c` ou écrire un fichier.

### 4.10 Pas de support first-class pour les reminders one-shot
- Aucun moyen propre pour un agent de dire "rappelle-moi à 18h15 ce soir". Faut créer un cron via l'API (pas exposé en tool), puis le nettoyer manuellement.

### 4.11 Observabilité limitée
- Pas d'UI pour voir le contenu d'une session passée.
- Logs Docker pas structurés côté agent (warnings émis par tool/runtime mais pas d'audit trail applicatif).
- Coût agrégé par agent/jour : pas d'endpoint, faut aggréger `usage_events` à la main.

### 4.12 Documentation upstream lacunaire
- Beaucoup de gotchas ci-dessus ne sont pas documentés chez RightNow-AI. On a dû reverse-engineer en lisant le code Rust.

## 5. Ce qu'on a dû ajouter / patcher nous-mêmes

- **Fork avec fix cron-loss** (kernel.rs, commit custom).
- **Scripts opérationnels** dans `scripts/` : `send.sh`, `test-agent.sh`, `snapshot.sh`, `seed-kv.sh`, `chat.sh`.
- **Entrypoint custom** pour cloner/pull le repo World Cup Bet au boot.
- **Doc ops complète** (`docs/openfang-operations.md`) — 9 gotchas documentés en détail.
- **3 crons manuels** pour EM (nudge/report/alert) — pas générés automatiquement depuis le manifest.
- **Prompt Leandro de ~300 lignes** avec pédagogie 3-phases, règles anti-exploration, format de message — beaucoup de prompt engineering parce que les comportements par défaut (bundled skills, tool defaults) ne matchent pas notre usage.

## 6. Requirements pour un remplacement (basés sur notre usage réel)

### Critiques (bloquant sans)
1. **Agent loop Anthropic** avec tool calls, streaming, budgets (tokens + iterations).
2. **KV persistent multi-namespace** (shared + self par agent), permissions fines lecture/écriture.
3. **Cron scheduler** fiable, survit aux restarts, délivrance fire-and-forget d'un message à un agent.
4. **Bridge Telegram** bidirectionnel (polling ou webhook), routing par chat_id.
5. **Hot-reload de prompt** sans redémarrer l'agent ni perdre la session.
6. **Agent-to-agent messaging** (un agent peut envoyer un message qui déclenche le loop d'un autre).
7. **Tools standards** : file_read/write/list, shell_exec whitelisté, web_search, channel_send, memory_store/recall.
8. **Persistance session** (historique conversationnel visible/requêtable).

### Importants (nice to have robustes)
9. **Schedule one-shot** (un agent peut programmer un rappel à une date précise, et ça fire effectivement).
10. **Event log auditable** — chaque message IN/OUT, tool call, état transition.
11. **Observabilité** : coût par agent, par jour, par session.
12. **Tests isolés** (snapshot/restore KV) — aujourd'hui on bricole avec scripts maison.
13. **Admin UI** : voir sessions, messages, coûts, et modifier les prompts live.

### Secondaires (ignorable sans douleur)
14. Knowledge graph.
15. Task queue inter-agents.
16. Event pub/sub.
17. Browser automation.

## 7. Alternatives à considérer (non exhaustif, sans recommandation)

- **LangGraph** (Python) + **APScheduler** + SQLite/Postgres — composants libres, bien éprouvés.
- **CrewAI** ou **AutoGen** — frameworks multi-agents, voir maturité cron/persistence.
- **Temporal** — si on veut du workflow engine solide, mais overkill pour 3 agents.
- **Inngest** / **Pipedream** — excellent cron + event-driven, mais payant et vendor-locked.
- **E2B** / **Daytona** — sandbox + runtime, moins cher qu'openfang niveau friction, moins d'outillage agent.
- **DIY minimal** : FastAPI + Celery/APScheduler + SQLite + Anthropic SDK direct. Moins de magie, moins de surprises, mais on réécrit l'agent loop.

Point non négociable si on bouge : on ne veut plus de "feature existe mais ne marche pas" — il faut pouvoir valider chaque brique (schedule, memory, cron, channel) avec un test end-to-end reproductible avant prod.

## 8. Effort estimé pour migrer

- Extraction des prompts + KV seed : faisable en 1 jour (déjà en .toml et scripts).
- Réécriture des 3 agents avec un nouveau runtime : 3–5 jours selon la stack choisie.
- Bridge Telegram : 1 jour (bot API standard).
- Cron + reminders : 1 jour si on part sur APScheduler ou équivalent.
- Migration KV : triviale (SQLite → SQLite ou export JSON).
- Tests end-to-end (simuler une session William, vérifier les nudges, les reports) : 1 jour.

Total grossier : **1 à 2 semaines** pour une réécriture propre, en mettant de côté les features non utilisées.
