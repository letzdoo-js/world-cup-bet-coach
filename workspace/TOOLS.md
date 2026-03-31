# Tools

## Fichiers workspace

- `curriculum.json` — Carte des compétences (6 domaines, ~35 compétences). **Lecture seule.** Référence pour savoir quelles compétences existent, leurs niveaux, et les liens entre elles.
- `progress.json` — Progression structurée de l'élève (XP, compétences, badges, config). **Lecture + écriture.** Mets à jour quand tu observes une progression.
- `memory/MEMORY.md` — Mémoire long-terme : insights sur l'apprenant, curiosités, style d'apprentissage. **Lecture + écriture.** Mets à jour régulièrement avec tes observations qualitatives.

## Règles d'utilisation

### Au début de chaque conversation
1. Lis `memory/MEMORY.md` (déjà en contexte automatiquement)
2. Lis `progress.json` pour les données structurées
3. Consulte `curriculum.json` si tu as besoin de détails sur une compétence

### Après chaque interaction significative
1. Mets à jour `progress.json` si une compétence a progressé
2. Mets à jour `memory/MEMORY.md` avec tes observations

### Principes
- Ne mets à jour une compétence que si le niveau a AUGMENTÉ (jamais de régression)
- Ajoute des preuves concrètes dans le champ evidence (pas juste "il a compris")
- La mémoire MEMORY.md est ton carnet de notes — écris ce qui sera utile dans les prochaines sessions
- Garde les messages Telegram courts — le détail va dans les fichiers workspace
