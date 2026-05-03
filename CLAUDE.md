# CLAUDE.md — guide pour Claude sur ce repo

Repo : openfang container `world-cup-bet-coach` qui fait tourner Leandro (tutor pour William, 14 ans, débutant total) + Magnus (interface Jerome) + engagement-monitor (cron de nudge/report).

**Toujours lire `docs/openfang-operations.md` avant de toucher aux agents, prompts, cron jobs.** Il documente les pièges (volume Docker non bind-mount, agents en SQLite pas en .toml, bug de perte des crons au restart).

## Scripts disponibles dans `scripts/`

| Script | Usage |
|---|---|
| `chat.sh <agent>` | Chat interactif avec un agent (REPL, pour debug manuel) |
| `send.sh <agent> "<message>"` | Envoie UN message, affiche la réponse + coût. Pas de backup KV. |
| `test-agent.sh <agent> "<msg1>" ["<msg2>" ...]` | **Test isolé** : backup KV → envoie les messages → restore KV → reset session. À utiliser pour toute simulation qui ne doit pas polluer l'état réel de William. |
| `snapshot.sh save \|restore \|list \|delete [name]` | Snapshot complet du volume `/app` (KV, sessions, config, repo). Plus lourd que `test-agent.sh` mais préserve TOUT. |
| `seed-kv.sh` | Reseed initial des `shared.*` KV. À ne JAMAIS lancer en prod, ça écrase la progression de William. |
| `entrypoint.sh` | Entrée Docker — clone/pull world-cup-bet, démarre openfang. |

## Comment tester Leandro (ou n'importe quel agent) sans casser William

**Pour une simulation rapide d'une session William** (ex: tester la pédagogie 3 phases sur f-string) :

```bash
./scripts/test-agent.sh leandro "salut"
```

Pour une conversation multi-tours scriptée d'avance :

```bash
./scripts/test-agent.sh leandro \
  "salut" \
  "c'est quoi une f-string ?" \
  "j'ai pas trop compris"
```

`test-agent.sh` :
1. Sauvegarde la KV de l'agent (`shared.progress`, `shared.competencies`, etc.)
2. Envoie les messages séquentiellement
3. Restaure la KV à l'identique
4. Reset la session

**Limitation :** les messages sont fixés à l'avance — si tu veux jouer un personnage qui réagit à ce que dit Leandro tour par tour, lance plusieurs `test-agent.sh` en chaîne (chaque appel restaure la KV → impossible) OU lance plusieurs `send.sh` sans backup, puis restaure manuellement à la fin (ou restaure depuis un `snapshot.sh save` pris avant).

**Pour une session interactive multi-tours réactive :**
1. `./scripts/snapshot.sh save before-test` — snapshot complet
2. `./scripts/send.sh leandro "salut"` — envoie, lis la réponse, décide la suivante
3. `./scripts/send.sh leandro "..."` — répète autant de fois que voulu
4. `./scripts/snapshot.sh restore before-test` — rollback total (arrête/redémarre le container, **attention §3 de openfang-operations : peut perdre les cron jobs**)

## Simuler William — règles pour le persona

- 14 ans, **zéro** formation IT
- Messages courts, en français, tutoiement, parfois fautes de frappe
- Ne connaît AUCUN terme tech (f-string, décorateur, fonction, JSON, terminal, path) — pose la question "c'est quoi" ou dit "j'ai pas compris"
- Ne devine JAMAIS ce qu'un mot anglais veut dire
- Si Leandro dit "tape /pret" ou "/done", William peut oublier et juste écrire "ok" ou "g fini"
- N'invente pas de connaissance qu'il n'a pas — si Leandro saute la Phase 1 (leçon) et passe direct à du code, William doit avoir l'air perdu
- Reste poli mais peut s'impatienter ("c'est trop dur", "j'ai pas envie", "explique mieux")

Le but du test est de **valider que Leandro applique bien le format 3-phases** (LEÇON → ATELIER scratch.py → INTÉGRATION main.py) et qu'il n'enchaîne pas direct sur du code à copier.

## Observer ce que Leandro fait dans la KV pendant le test

```bash
docker exec world-cup-bet-coach python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/data/openfang.db')
for k in ['shared.progress','shared.competencies','shared.learning_style']:
    r = c.execute('SELECT value FROM kv_store WHERE key=?',(k,)).fetchone()
    print('===',k); print(json.loads(r[0]) if r else None); print()
"
```

## Mettre à jour un prompt d'agent (le bon pattern)

**JAMAIS** : éditer `agents/*.toml` puis `docker restart`. Trois raisons : (1) `/app` est un volume, le restart ne lit pas le host, (2) les agents sont chargés depuis SQLite pas depuis le `.toml`, (3) le restart wipe les cron jobs.

**TOUJOURS** : `PATCH /api/agents/{id}` avec `{"system_prompt": "..."}`. Hot-reload, persisté en SQLite, pas de restart. Voir `docs/openfang-operations.md` §2 pour le snippet Python.

Et après le PATCH, pour pousser proprement le changement aussi dans le fichier source (pour git) :
```bash
cat agents/tutor.toml | docker exec -i world-cup-bet-coach sh -c 'cat > /app/agents/tutor.toml'
cat agents/tutor.toml | docker exec -i world-cup-bet-coach sh -c 'cat > /app/agents/leandro/agent.toml'
```

**Les deux chemins existent** : `/app/agents/tutor.toml` (legacy, lu au boot) et `/app/agents/leandro/agent.toml` (nested, lu par le TOML→DB sync). Écrire les deux évite toute désync. Pareil pour parent.toml → magnus/agent.toml, engagement-monitor.toml → engagement-monitor/agent.toml.

## Pièges opérationnels récurrents (lis avant d'intervenir sur les agents)

Ces gotchas m'ont coûté du temps à chaque intervention — à relire avant de toucher à l'API ou à la DB.

### API openfang : adresse, port, pas de curl dans le container

- Port : **4200 interne**, pas 3000 ni 8080. Pas exposé sur le host par défaut.
- **Pas de `curl` dans le container** — l'image est alpine-like mais sans curl. Utilise Python (urllib) ou fais les requêtes **depuis le host** vers l'IP du container.
- L'IP du container change à chaque redémarrage. Pour la récupérer :
  ```bash
  CIP=$(docker inspect world-cup-bet-coach --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | awk '{print $1}')
  curl -s http://$CIP:4200/api/agents
  ```
- `docker port world-cup-bet-coach` ne montre rien d'utile (le port 4200/tcp est déclaré mais pas publié). Toujours passer par l'IP interne.

### PATCH /api/agents/{id} : vérifier via SQLite, pas via GET

- `GET /api/agents/{id}` **ne renvoie pas `system_prompt`** (champ omis de la réponse). Pour vérifier qu'un PATCH a propagé, requête directement SQLite :
  ```bash
  docker cp world-cup-bet-coach:/app/data/openfang.db /tmp/openfang.db
  docker cp world-cup-bet-coach:/app/data/openfang.db-wal /tmp/openfang.db-wal
  python3 -c "
  import sqlite3, msgpack
  c = sqlite3.connect('/tmp/openfang.db')
  row = c.execute(\"SELECT manifest FROM agents WHERE name='leandro'\").fetchone()
  m = msgpack.unpackb(row[0], raw=False)
  print(m['model']['system_prompt'][:500])
  "
  ```
- **Toujours copier `openfang.db-wal` avec `openfang.db`** quand tu lis la DB — les écritures récentes (dernière ~30 min) sont en WAL, pas dans le fichier principal. Sans WAL tu lis des données périmées.

### Formats de stockage SQLite

- `sessions.messages` : **msgpack**, pas JSON. `pip install --user --break-system-packages msgpack` sur le host pour décoder.
- `agents.manifest` : msgpack aussi. Champ `system_prompt` est dans `manifest['model']['system_prompt']`.
- `events` est vide en pratique — ne compte pas dessus pour retrouver l'historique des messages.
- `usage_events` est la source de vérité pour les coûts LLM par appel (timestamp, agent, input/output tokens, $).

### Récupérer une session passée

La table `sessions` ne garde **qu'UNE session active par agent** (même session réutilisée), et les vieux messages sont **trimmés au fur et à mesure** (`Trimming old messages to prevent context overflow` dans les logs). Pour reconstruire ce qu'un user a écrit il y a plusieurs jours, les messages ne sont plus là — il faut croiser `docker logs` (timestamps + token counts) avec `usage_events` (coûts) et parfois la queue Telegram si elle est persistée.

### Heredoc Python via `docker exec` : silencieux, utilise `-c` ou un fichier

`docker exec world-cup-bet-coach python3 << 'PYEOF' ... PYEOF` **ne rend pas la sortie visible** depuis le host (stdin se comporte bizarrement avec les sessions TTY-less). Trois options qui marchent :
1. `docker exec world-cup-bet-coach python3 -c "..."` — le plus simple pour du court.
2. Copier la DB sur le host (`docker cp`) et exécuter Python **sur le host** — préféré pour tout ce qui est analyse.
3. Écrire le script dans `/tmp/foo.py` via `sh -c "cat > /tmp/foo.py"` puis `docker exec ... python3 /tmp/foo.py`.

### `cat foo | docker exec -i ... 'cat > file1 && cat > file2'`

**Ne marche pas** : le premier `cat` consomme stdin, le second lit du vide et écrit un fichier de 0 byte. Toujours faire deux commandes séparées (voir snippet plus haut).

### Installer un paquet dans le container

`pip install` et `pip install --break-system-packages` échouent tous les deux : `/root/.local` est read-only, et le container n'est pas censé muter. Installer sur le **host** avec `pip3 install --user --break-system-packages <pkg>` et parser les données SQLite localement après `docker cp`.

## Liens

- Référence opérationnelle complète : [`docs/openfang-operations.md`](docs/openfang-operations.md)
- Spec et plan de la migration OpenFang : `docs/superpowers/specs/2026-04-02-openfang-migration-design.md`, `docs/superpowers/plans/2026-04-02-openfang-migration.md`
