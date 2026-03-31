# 🐾 World Cup Bet Coach v2 — Mentor Adaptatif pour World Cup Bet

Bot Telegram de mentorat adaptatif propulsé par [nanobot](https://github.com/nanobotai/nanobot) + Claude.

## Philosophie

World Cup Bet Coach n'est **pas un cours en ligne**. C'est un mentor adaptatif qui :
- **Suit la curiosité** de l'élève comme fil conducteur
- **Tisse les apprentissages** naturellement dans la conversation
- **Évalue invisiblement** — des questions naturelles, pas des quiz formels
- **Couvre tout l'univers du dev** — pas juste le code, mais aussi comment marchent les ordis, Internet, les serveurs, les outils

L'élève construit **World Cup Bet**, une app de pronostics pour la Coupe du Monde 2026. Ça donne du sens à chaque concept appris.

## Structure

```
clawbot/
├── setup.sh                      ← Lance ça
├── config.json.template          ← Template config nanobot
├── Dockerfile
├── docker-compose.yml
├── botfather-commands.txt        ← Commandes pour @BotFather
├── skills/
│   ├── clawbot-tutor/
│   │   └── SKILL.md              ← Skill principal — mentor adaptatif
│   └── clawbot-quiz/
│       └── SKILL.md              ← Évaluation conversationnelle
└── workspace/
    ├── SOUL.md                   ← Personnalité et philosophie
    ├── AGENTS.md                 ← Instructions opérationnelles
    ├── USER.md                   ← Profil élève + parent
    ├── TOOLS.md                  ← Règles d'utilisation des outils
    ├── HEARTBEAT.md              ← Check-ins périodiques
    ├── memory/
    │   └── MEMORY.md             ← Mémoire long-terme (insights apprenant)
    ├── curriculum.json            ← Carte des compétences (6 domaines, ~35 compétences)
    └── progress.json              ← Progression structurée (XP, niveaux, config)
```

## Setup

```bash
# 1. Copie et édite la config
cp config.json.template config.json
nano config.json
# Remplace les REPLACE_... avec tes vraies clés

# 2. Édite USER.md avec les telegram IDs
nano workspace/USER.md

# 3. Lance
chmod +x setup.sh
./setup.sh

# 4. Teste : envoie /start au bot sur Telegram
```

## Pré-requis

1. **Token Telegram** : crée un bot via @BotFather, copie le token
2. **Clé Anthropic** : https://console.anthropic.com/ (pour Claude)
3. **IDs Telegram** : envoie un message à @userinfobot pour avoir les IDs
4. **Docker** avec compose

## Commandes

### Élève
| Commande | Action |
|----------|--------|
| `/start` | Bienvenue / reprend la conversation |
| `/explore [sujet]` | Explorer un sujet ou voir les pistes |
| `/build` | Prochaine feature à construire |
| `/whatis <x>` | Explique un concept |
| `/debug` | Aide au debugging guidé |
| `/code` | Soumettre du code pour review |
| `/progress` | Carte de progression |
| `/hint` | Un coup de pouce contextuel |
| `/quiz` | Évaluation conversationnelle |

### Parent
| Commande | Action |
|----------|--------|
| `/plan` | Carte des compétences avec statuts |
| `/rapport` | Rapport détaillé de progression |
| `/config` | Régler le rythme, les priorités |

## Domaines couverts

- 🖥️ **Comment marche un ordi** — binaire, CPU, RAM, OS, fichiers
- 🌐 **Comment marche Internet** — IP, DNS, paquets, HTTP, TLS
- 🐍 **Code Python** — variables → FastAPI, en passant par tout
- 💾 **Données** — JSON, fichiers, SQL, modélisation
- 🔧 **Outils** — terminal, Git, VS Code, packages
- 🏗️ **Infrastructure** — serveurs, déploiement, CI/CD, Docker

## Crons suggérés

```bash
# Check-in engageant si inactif (18h chaque jour)
nanobot cron add --name "engagement" \
  --message "Vérifie si l'élève est inactif depuis plus de 48h. Si oui, envoie un message engageant lié à sa dernière curiosité." \
  --cron "0 18 * * *"

# Rapport parent hebdomadaire (dimanche 20h)
nanobot cron add --name "weekly_rapport" \
  --message "Génère et envoie le rapport hebdomadaire au parent (même format que /rapport)." \
  --cron "0 20 * * 0"
```
