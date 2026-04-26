# hal

<p align="center">
  <img src="logo.png" alt="HAL 9000" width="200" />
</p>

> *"I'm sorry Dave, I'm afraid I can't do that."*

CLI workflow-friendly pour l'API **hal** (OpenAI-compatible chat completions). Disponible en Bash et PowerShell.

## Démo

[![Démo HAL CLI](https://img.youtube.com/vi/NqCCubrky00/0.jpg)](https://www.youtube.com/watch?v=NqCCubrky00)

```
hal/
├── src/              # Scripts sources
│   ├── hal.sh        # Bash (Linux / macOS / WSL)
│   └── hal.ps1       # PowerShell (Windows)
├── install/          # Installateurs
│   ├── install.sh    # Installateur Bash
│   └── install.ps1   # Installateur PowerShell
├── Makefile          # Install / test / build
├── README.md         # Version anglaise
├── README_FR.md      # Ce fichier
├── CHANGELOG.md      # Historique des versions
├── CONTRIBUTING.md   # Guide de contribution
├── LICENSE           # Licence MIT
└── logo.png          # HAL 9000
```

---

## Déployer HAL

### One-liner install (Linux / macOS / WSL)

```bash
curl -sL https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.sh | sudo tee /usr/local/bin/hal > /dev/null && sudo chmod +x /usr/local/bin/hal
```

### One-liner install (Windows PowerShell)

```powershell
iwr -Uri https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.ps1 -OutFile hal.ps1
```

### Via make

```bash
make install
```

### Via script d'installation

```bash
chmod +x install/install.sh
sudo ./install.sh install
```

### Manuellement

```bash
chmod +x src/hal.sh
sudo cp src/hal.sh /usr/local/bin/hal
```

### Dépendances

- `curl`
- `python3` (Bash uniquement — JSON handling)

```bash
make install-deps   # Debian/Ubuntu, macOS, Arch, Fedora
```

---

## Paramètres de mission

Configurez HAL via les variables d'environnement :

| Variable | Description | Défaut |
|----------|-------------|--------|
| `HAL_API_BASE` | URL de base de l'API | *(défaut interne)* |
| `HAL_API_KEY` | Clé API (si requise) | *(aucune)* |
| `HAL_MODEL` | Modèle par défaut | `gpt-4o` |
| `HAL_CACHE_ENABLED` | Activer le cache local | `1` |
| `HAL_MAX_RETRIES` | Tentatives en cas d'échec | `3` |
| `HAL_RETRY_DELAY` | Délai entre retries (sec) | `2` |

---

## Cerveaux testés en vol

L'API hal n'expose pas de endpoint `/v1/models`. Les modèles ci-dessous ont été **validés un par un par appels réels** pendant le développement :

| Modèle | Description |
|--------|-------------|
| `gpt-4o` | GPT-4o (défaut) — rapide et polyvalent |
| `gpt-4o-mini` | Version légère et économique |
| `gpt-4-turbo` | GPT-4 Turbo |
| `gpt-4` | GPT-4 classique |
| `o1` | Modèle de raisonnement avancé |
| `o3-mini` | Version légère de raisonnement |
| `claude-sonnet-4` | Claude Sonnet |
| `claude-opus-4` | Claude Opus (le plus puissant) |
| `gemini-1.5-pro` | Google Gemini 1.5 Pro |
| `fast` | Modèle rapide / allégé |
| `llama` | Meta Llama |

Lister les cerveaux disponibles :

```bash
hal --list-models
```

Changer de cerveau à la volée :

```bash
hal --chat "Code un quicksort en Rust" --model claude-opus-4
hal --chat "Résumé rapide" --model fast
```

---

## Dialoguer avec HAL

### Message positionnel (le plus simple)

```bash
hal "Explique la relativité restreinte"
```

### Avec options explicites

```bash
hal --chat "Hello" --output raw --quiet
```

### Pipe stdin (idéal pour les scripts)

```bash
echo "Résume ceci" | hal --system "Sois concis" --quiet | jq -r '.choices[0].message.content'
```

### Avec system prompt et modèle

```bash
hal --chat "Review this code" --system "You are a senior Go developer" --model gpt-4o
```

### Paramètres de génération

```bash
hal --chat "Poème sur l'automne" --temperature 0.9 --max-tokens 200
```

### Utiliser un proxy local

```bash
hal --chat "ping" --api-base http://localhost:8080
```

---

## Analyse de données sensorielles

### Joindre un fichier texte

```bash
hal --chat "Résume ce fichier" --file notes.md
hal --chat "Compare ces deux fichiers" --file a.md --file b.md
```

Le contenu est formaté exactement comme dans les requêtes capturées de l'application web :

```
--- filename ---
contenu du fichier

message utilisateur
```

### Joindre une image

```bash
hal --chat "Décris cette image" --image photo.png
hal --chat "Compare ces images" --image a.png --image b.png
```

Les images sont encodées en base64 au format multimodal OpenAI.

### Mixer fichiers texte + images

```bash
hal --chat "Review ce code et dis-moi si l'UI correspond" \
  --file app.tsx --image screenshot.png
```

---

## Options CLI

```
--chat "MSG"        Message à envoyer
--model MODEL       Modèle (défaut: gpt-4o)
--system "PROMPT"   System prompt
--temperature N     Température (0–2)
--max-tokens N      Max tokens
--api-base URL      URL de base de l'API
--api-key KEY       Clé API
--output json|raw   Format de sortie (défaut: json)
--file PATH         Joindre un fichier texte (répétable)
--image PATH        Joindre une image (répétable)
--list-models       Afficher les modèles disponibles
--update            Mettre à jour le script depuis GitHub
--update-force      Forcer la mise à jour même si déjà à jour
--no-cache          Désactiver le cache local
--quiet             Supprimer les logs stderr
-v, --version       Afficher la version
-h, --help          Aide (disponible à tout niveau)
```

> **Note sur l'aide :** `--help` fonctionne partout. Même `hal --model --help` affiche l'aide au lieu de planter.

---

## Mémoire de bord

Les réponses sont mises en cache dans `~/.cache/hal/`.

Contrairement à un cache basique, la clé est calculée à partir du **contenu** des fichiers et images joints (hash MD5), pas seulement de leurs chemins. Modifiez un fichier, le cache invalide automatiquement.

Désactivez avec `HAL_CACHE_ENABLED=0` ou `--no-cache`.

---

## Protocoles automatiques

### GitHub Actions

```yaml
- name: Ask hal
  run: |
    RESPONSE=$(./src/hal.sh --chat "Génère un changelog pour ce tag" --quiet | jq -r '.choices[0].message.content')
    echo "## Réponse hal" >> $GITHUB_STEP_SUMMARY
    echo "$RESPONSE" >> $GITHUB_STEP_SUMMARY
```

### Scripting en pipeline

```bash
#!/bin/bash
set -euo pipefail

DIFF=$(git diff HEAD~1)
REVIEW=$(echo "$DIFF" | hal --system "Tu es un senior dev. Sois concis." --quiet)
echo "$REVIEW"
```

---

## Quand HAL refuse

Deux types d'erreurs, deux comportements :

- **Erreurs utilisateur** (argument manquant, fichier introuvable, option inconnue) : message clair sur **stderr**, exit code `1` ou `2`
- **Erreurs API** (HTTP, timeout, réponse invalide) : format respecté selon `--output` :
  - `--output json` → `{"error": "..."}` sur stdout
  - `--output raw` → `ERROR: ...` sur stderr

---

## Auto-mise à jour

Mettez à jour HAL directement depuis GitHub sans réinstaller :

```bash
hal --update          # met à jour seulement si une nouvelle version existe
hal --update-force    # force la réinstallation de la dernière version
```

PowerShell :

```powershell
.\hal.ps1 -Update
.\hal.ps1 -UpdateForce
```

---

## Mise à jour système

```bash
make build    # crée dist/hal.tar.gz
make test     # teste hal.sh et hal.ps1
make clean    # nettoie dist/
```

---

## Licence

MIT — Dave, this conversation can serve no purpose anymore. Goodbye.
