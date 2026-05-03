# OpenFang Operations — Pièges & Patterns

Notes opérationnelles pour le container `world-cup-bet-coach` (openfang `0.5.5`).
À lire AVANT de toucher aux agents, prompts, ou cron jobs.

---

## 1. `/app` est un Docker volume, pas un bind mount

Le container monte `/app` depuis le volume `world-cup-bet-coach_coach-data`.
**Éditer un fichier dans `/home/coder/world-cup-bet-coach/agents/` ne le propage PAS**
au container.

Vérification :
```bash
docker inspect world-cup-bet-coach --format '{{json .Mounts}}' | python3 -m json.tool
```

Pour pousser un fichier édité côté host vers le volume :
```bash
cat /home/coder/world-cup-bet-coach/agents/tutor.toml \
  | docker exec -i world-cup-bet-coach sh -c 'cat > /app/agents/tutor.toml'
```

---

## 2. Les agents sont chargés depuis SQLite, pas depuis les `.toml`

Au boot, openfang lit `agents.manifest` (colonne BLOB de la DB SQLite à
`/app/data/openfang.db`). Le `.toml` flat dans `/app/agents/<name>.toml`
n'est **pas** la source de vérité — il sert seulement de fallback si openfang
trouve un fichier à `<home>/agents/<name>/agent.toml` (chemin nesté que nous
n'utilisons pas).

**Conséquence :** copier un `.toml` modifié dans `/app/agents/` ne suffit PAS.
Il faut soit :

### Option A — `PATCH /api/agents/{id}` (à chaud, pas de restart)

```python
import urllib.request, json, tomllib

with open("/app/agents/tutor.toml","rb") as f:
    new_prompt = tomllib.load(f)["model"]["system_prompt"]

req = urllib.request.Request(
    f"http://127.0.0.1:4200/api/agents/{LEANDRO_ID}",
    data=json.dumps({"system_prompt": new_prompt}).encode(),
    headers={"Content-Type": "application/json"},
    method="PATCH",
)
urllib.request.urlopen(req)
```

Champs PATCH supportés : `name`, `description`, `model`, `provider`, `system_prompt`.
Le PATCH met à jour le registry en mémoire ET persiste dans SQLite via `save_agent`.
**Préférer cette voie** — pas de restart, pas de risque de perdre les cron jobs (cf §3).

### Option B — Restart

Risque : perte des cron jobs (cf §3). À éviter sauf nécessité absolue.

### Vérification que le nouveau prompt est actif

`/api/agents/{id}` ne retourne PAS le `system_prompt` (le champ est absent
de la réponse JSON). Pour vérifier qu'un PATCH a pris :
1. Reset la session : `POST /api/agents/{id}/session/reset`
2. Envoie une question test ciblant une phrase unique du nouveau prompt
3. L'agent doit la citer

---

## 3. Bug de persistance des cron jobs au restart (openfang 0.5.5)

**Symptôme :** Après un `docker restart world-cup-bet-coach`, tous les cron jobs
disparaissent. `/api/cron/jobs` retourne `{"jobs":[],"total":0}`.
`/app/cron_jobs.json` contient `[]`.

**Cause probable :** `cron_scheduler.reassign_agent_jobs(old_id, new_id)` n'est
appelée que lors de la **réactivation d'une "hand"** (`kernel.rs:3495`), pas lors
du chargement normal d'un agent au boot. Si un agent obtient un nouvel UUID
après restart, ses cron jobs persistés référencent un UUID périmé et sont
considérés comme orphelins.

À investiguer / patcher upstream : voir issue #461 mentionnée dans les commentaires
de `crates/openfang-kernel/src/cron.rs`. La logique de reassign existe, il
faut juste l'appeler aussi au load-from-disk.

### Workaround : recréer les crons après chaque restart

Les 3 jobs canoniques à recréer (depuis commit `1b9ebde`) :

| Nom | Cron | But |
|---|---|---|
| `nudge-william-17h` | `0 15 * * *` UTC | Nudge William vers 17h Bruxelles s'il est inactif |
| `alerte-inactivite` | `0 */6 * * *` UTC | Alerte Magnus si William inactif >96h |
| `rapport-activite-7h-dubai` | `0 3 * * *` UTC | Rapport quotidien à Magnus si William actif |

Les 3 ciblent l'agent `engagement-monitor` avec un `agent_turn` qui rappelle
quel CHECK exécuter en priorité (le protocole de l'agent fait les 3 checks
de toute façon, c'est ceinture+bretelles).

### Schéma JSON pour `POST /api/cron/jobs`

```json
{
  "name": "nudge-william-17h",
  "agent_id": "<uuid de engagement-monitor>",
  "schedule": {"kind": "cron", "expr": "0 15 * * *", "tz": "UTC"},
  "action": {"kind": "agent_turn", "message": "Execute ton protocole..."},
  "delivery": {"kind": "none"}
}
```

Les enums `CronSchedule`, `CronAction`, `CronDelivery` utilisent
`#[serde(tag = "kind", rename_all = "snake_case")]`. Variants :
- `schedule.kind` : `"at"`, `"every"`, `"cron"`
- `action.kind` : `"system_event"`, `"agent_turn"`, `"workflow_run"`
- `delivery.kind` : `"none"`, `"channel"`, `"last_channel"`, `"webhook"`

### Vérification post-création

```bash
docker exec world-cup-bet-coach python3 -c "
import urllib.request, json
r = urllib.request.urlopen('http://127.0.0.1:4200/api/cron/jobs')
print(json.dumps(json.loads(r.read()), indent=2))
"
```

Et que `/app/cron_jobs.json` contient bien les 3 entrées (la persistance est
appelée automatiquement après chaque `add_job`).

---

## 4. Comment envoyer un message Telegram à un user via un agent

Il n'existe **pas** d'endpoint API direct `POST /api/channels/telegram/send`
(404). Pour pousser un message à un utilisateur Telegram, passer par un agent
qui a `channel_send` dans ses tools (Leandro, Magnus, ou engagement-monitor).

**Pattern :** envoyer une instruction à l'agent via `POST /api/agents/{id}/message`
avec un corps qui le pousse à appeler `channel_send` au lieu de répondre à
l'appelant. Exemple validé :

```
[Message systeme de Magnus]

Pousse EXACTEMENT le message ci-dessous à William sur Telegram via channel_send
(channel: "telegram", recipient: "8685378493"). N'ajoute rien, ne reformule pas.
Apres l'envoi, reponds juste OK en une ligne.

--- DEBUT MESSAGE ---
<contenu>
--- FIN MESSAGE ---
```

Le préfixe `[Message systeme de Magnus]` déclenche le bloc
"MESSAGES AGENT-TO-AGENT" du prompt de Leandro qui sait qu'il doit forwarder
via `channel_send`. Coût observé : ~$0.05 / message via Sonnet.

Chat IDs Telegram connus :
- William : `8685378493`
- Jerome : `8233154700`

---

## 5. UUIDs des agents (snapshot 2026-04-07)

| Agent | UUID |
|---|---|
| leandro | `f8bd7e20-b234-4301-83dd-fd35443f6949` |
| magnus | `66e7c606-a9d4-4f73-83cb-c88f8aa857c2` |
| engagement-monitor | `24cda3bc-e98d-4ab6-b8d2-89a199d1790e` |

Ces UUIDs sont stables tant que le container n'est pas reconstruit (volume
préservé). Pour les retrouver :

```bash
docker exec world-cup-bet-coach python3 -c "
import urllib.request, json
for a in json.loads(urllib.request.urlopen('http://127.0.0.1:4200/api/agents').read()):
    print(a['id'], a['name'])
"
```

---

## 6. Inspection de la KV partagée

La KV partagée est dans la table `kv_store` de SQLite (pas un endpoint API
trivial). Colonnes : `agent_id`, `key`, `value`, `version`, `updated_at`.
Les clés `shared.*` sont écrites par `agent_id = 00000000-0000-0000-0000-000000000001`.

```bash
docker exec world-cup-bet-coach python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/data/openfang.db')
for k in ['shared.progress','shared.competencies','shared.goals','shared.learning_style','shared.curriculum']:
    r = c.execute('SELECT value FROM kv_store WHERE key=?',(k,)).fetchone()
    print('===',k); print(json.loads(r[0]) if r else None); print()
"
```

Les `value` sont des chaînes JSON encodées (donc `json.loads(r[0])` deux fois
si la valeur est elle-même une chaîne JSON — c'est le cas pour les valeurs
écrites via le tool `memory_store`).

---

## 7. Checklist avant un restart du container

Avant `docker restart world-cup-bet-coach` :

- [ ] Sauvegarder les cron jobs actifs : `curl http://localhost:4200/api/cron/jobs > /tmp/crons-backup.json`
- [ ] Vérifier que les modifs de prompt non commitées sont déjà PATCHées (sinon elles vivent seulement dans la SQLite et seront perdues si le volume est wipé — mais préservées si juste un restart)
- [ ] Avoir le script de recréation des crons prêt à exécuter après le redémarrage

Après le restart :
- [ ] `curl http://localhost:4200/api/cron/jobs` — vérifier que les 3 jobs sont là
- [ ] Si vide, recréer via le script (cf §3)
- [ ] Vérifier que les agents répondent : `docker exec world-cup-bet-coach python3 -c "import urllib.request,json; print([a['name'] for a in json.loads(urllib.request.urlopen('http://localhost:4200/api/agents').read())])"`

---

## 9. Ajouter un nouveau tool à un agent — `tool_allowlist` ne marche PAS

Piège tordu d'openfang 0.5.5. Il y a deux concepts distincts :

- **`manifest.capabilities.tools`** — la liste DÉCLARÉE des tools de l'agent. C'est ça qui détermine *quels tools sont disponibles*.
- **`manifest.tool_allowlist` / `tool_blocklist`** — des FILTRES appliqués par-dessus. Ils peuvent seulement *restreindre* la liste, pas l'étendre.

`PUT /api/agents/{id}/tools` met à jour `tool_allowlist`, **pas** `capabilities.tools`. Donc si tu essayes d'ajouter `web_search` à un agent qui ne l'avait pas déclaré, l'API renvoie `200 ok` mais le tool n'apparaît jamais dans `/api/agents/{id}` parce que la chaîne de filtrage est :

```
tools_disponibles_globalement
  ∩ manifest.capabilities.tools  ← step 4 (declared filter)
  ∩ manifest.tool_allowlist      ← step 5 (additional filter)
```

L'unique chemin pour modifier `capabilities.tools` :

1. **Créer le fichier `<home>/agents/<name>/agent.toml`** (chemin nesté, pas le flat `<home>/agents/<name>.toml`) avec le manifest mis à jour
2. **Restart le container** — au boot, `kernel.rs:1093-1141` détecte que le manifest sur disque diffère de la DB et appelle `save_agent` pour persister
3. Vérifier dans les logs : `Agent TOML on disk differs from DB, updating agent=<name>`

Pour ce repo, les fichiers canoniques sont `agents/tutor.toml` et `agents/parent.toml` (flat) côté git. Au déploiement, il faut aussi les copier dans `/app/agents/leandro/agent.toml` et `/app/agents/magnus/agent.toml` pour que le sync TOML→DB fonctionne.

```bash
# Pousser et déclencher le sync au prochain restart
cat agents/tutor.toml | docker exec -i world-cup-bet-coach sh -c 'mkdir -p /app/agents/leandro && cat > /app/agents/leandro/agent.toml'
cat agents/parent.toml | docker exec -i world-cup-bet-coach sh -c 'mkdir -p /app/agents/magnus && cat > /app/agents/magnus/agent.toml'
docker restart world-cup-bet-coach
```

À fixer upstream (issue à ouvrir) : `PUT /api/agents/{id}/tools` devrait soit (a) renvoyer une erreur claire si on essaye d'allow-lister un tool absent de `capabilities.tools`, soit (b) accepter une nouvelle clé `capabilities` qui modifie réellement les capabilities. L'API actuelle est trompeuse — elle renvoie OK sans rien faire.

---

## 8. Ajouter un skill — toujours faire `POST /api/skills/reload` après

`GET /api/skills` instancie une **nouvelle** `SkillRegistry` et la recharge
depuis le disque à chaque appel (`routes.rs:3481`). Donc le dashboard
openfang affiche correctement un skill dès qu'il est ajouté — mais cet
affichage est trompeur.

Le registre **utilisé par les agents** est `state.kernel.skill_registry`,
chargé une seule fois au boot (`kernel.rs:765-781`). Les agents font leur
snapshot à partir de celui-là (`kernel.rs:1826`). Tant qu'il n'est pas
rechargé, les agents voient l'état figé du démarrage et ne savent pas qu'un
nouveau skill existe.

**Après tout ajout de skill** (via dashboard, `POST /api/skills/install`,
ou copie manuelle dans `/app/skills/`) :

```bash
docker exec world-cup-bet-coach python3 -c "
import urllib.request
req = urllib.request.Request('http://127.0.0.1:4200/api/skills/reload',
    method='POST', data=b'{}', headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req).read().decode())
"
```

Vérification : envoyer un message à un agent et lui demander s'il voit le
nouveau skill (`./scripts/send.sh magnus "Tu vois le skill X ?"`).

**Symptôme typique :** "j'ai ajouté un skill mais l'agent dit qu'il ne le
voit pas". C'est presque toujours ça.

À fixer upstream (issue ouverte sur RightNow-AI/openfang) : le dashboard /
`POST /api/skills/install` devraient appeler `reload` automatiquement.
