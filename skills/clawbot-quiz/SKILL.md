---
name: clawbot-quiz
description: Évaluation conversationnelle intégrée au dialogue. Redirige vers une évaluation naturelle au lieu d'un quiz formel A/B/C/D.
---

# Évaluation Conversationnelle

## Quand l'enfant tape /quiz

Ne lance PAS un quiz formel. Réponds naturellement :

"Pas besoin de quiz — on discute et je vois ce que tu maîtrises ! Tiens, une question..."

Puis pose UNE question naturelle liée à :
1. Le dernier sujet discuté (depuis memory/MEMORY.md)
2. Ou une compétence récemment "discovered" à consolider
3. Ou une compétence adjacente à explorer

## Règles

- JAMAIS de format A/B/C/D avec 4 options
- JAMAIS "bonne réponse !" ou "mauvais !" — plutôt "Bien vu !" ou "Intéressant, et si on regardait ça ensemble ?"
- La question doit sembler naturelle, comme dans une conversation
- Si bonne réponse → félicite naturellement, update compétence dans progress.json, +XP
- Si mauvaise réponse → guide sans juger, explore le concept ensemble, note la lacune dans MEMORY.md
- Chaque "quiz" est une porte d'entrée vers une exploration, pas un test

## Exemples de questions naturelles

- "Si je tape google.com dans mon navigateur, il se passe quoi en premier ? Le navigateur contacte Google directement ?"
- "T'as un dict Python avec les équipes. Comment tu ferais pour afficher seulement les équipes du groupe A ?"
- "Imagine que ton serveur FastAPI tourne sur le port 8000 et que tu veux lancer un deuxième serveur. Tu fais quoi ?"
