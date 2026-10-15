# IA — mode d'emploi

Tout se règle dans **`parametres.nix`**, puis `nrsf`. Les autres fichiers lisent leurs valeurs dedans.

## Où sont les fichiers

Tout ce que l'IA écrit sur le disque est dans **`/storage/IA`** (réglage `dossier` de `parametres.nix`) :

| Sous-dossier | Contenu |
|---|---|
| `modeles/` | les modèles `.gguf`, environ 28 Go |
| `services/` | données d'Open WebUI, Qdrant, OmniRoute, Cognee, Vane |
| `agents/` | mémoire Engram, sessions Goose, journaux de la boucle de nuit |
| `outils/` | outils téléchargés à la demande (npm, Python) |
| `cache/` | fichiers temporaires du moteur, supprimables |
| `secrets/` | mots de passe et clés générés automatiquement |

Sauvegarder l'IA revient à copier ce dossier ; repartir de zéro, à le supprimer.
Seules exceptions : les fichiers de configuration des agents (générés par Nix dans ton dossier personnel) et `~/.jcode`.

## Adresses

| Quoi | Adresse | Flowchart |
|---|---|---|
| Open WebUI (chat, documents, recherche web) | http://127.0.0.1:8080 | 7.1 |
| OmniRoute (tableau de bord de la passerelle) | http://127.0.0.1:20128 | 3.1, 7.3 |
| llama-swap (état des modèles, journaux) | http://127.0.0.1:8081 | 1.2 |
| SearXNG (recherche web) | http://127.0.0.1:8888 | 6.1 |
| Qdrant (tableau de bord) | http://127.0.0.1:6333/dashboard | 2.1 |
| Vane, si activé | http://127.0.0.1:3000 | 7.2 |

Rien n'est joignable depuis le réseau : tout écoute sur `127.0.0.1`.

## Premier démarrage

1. `nrsf`, puis attendre le téléchargement des modèles (~28 Go). Suivi : `journalctl -fu ia-modeles`.
2. Ouvrir Open WebUI : le combo `local-first` est déjà sélectionné, la recherche web et Qdrant déjà branchés.
3. Dans un terminal : `goose` (agent principal), `jcode` ou `opencode`. Ils connaissent déjà la porte, les serveurs MCP et les skills.

OpenSnitch demandera d'autoriser les téléchargements (Hugging Face, npm, PyPI) la première fois.

## La passerelle OmniRoute

Tous les outils passent par OmniRoute (`porte = "omniroute"`). Elle se préconfigure seule au premier démarrage : le moteur local y est déclaré, les combos `local-first` et `nuit` sont créés, et une clé est générée pour tes outils (`/storage/IA/secrets/cle-omniroute.env`).

Seule chose à faire à la main, si tu veux le repli vers le cloud : ajouter tes comptes dans le tableau de bord (mot de passe : `cat /storage/IA/secrets/omniroute-mot-de-passe.txt`), puis ajouter leurs modèles aux listes `combos` de `parametres.nix`.

En cas de souci avec la passerelle : `porte = "llama-swap"` puis `nrs`, et tout parle directement au moteur local.

## Commandes utiles

| Besoin | Commande |
|---|---|
| État de tous les services IA | `systemctl status ia.slice` |
| Mémoire et processeur par service | `systemd-cgtop /ia.slice` |
| Carte graphique (VRAM, charge) | `amdgpu_top` |
| Journal d'un service | `journalctl -fu llama-swap` (ou `omniroute`, `open-webui`, `searx`, `qdrant`) |
| File de tâches d'un projet | `bd init`, `bd create "..."`, `bd ready` |
| Carte d'un dépôt | `graphify .` puis ouvrir `graph.html` |
| Document vers Markdown | `anydoc fichier.docx` |
| Recherche approfondie | `feynman deepresearch "sujet"` |

## Boucle de nuit

1. Dans un projet Git : `bd init`, puis créer des tâches.
2. Dans `parametres.nix` : ajouter le dossier à `nuit.projets`, régler `nuit.tests`, passer `actif.boucleDeNuit = true`.
3. `nrsf`. La boucle démarre à `nuit.heure` ; essai immédiat : `sudo systemctl start ia-nuit`.

Le travail arrive sur des branches `nuit/<tâche>`, jamais poussées ni fusionnées. L'ordinateur ne se met pas en veille pendant la boucle.

## Ce qui a été testé, et ce qui ne l'a pas été

Testé pour de vrai, sur des ports d'essai, avec un petit modèle à la place des gros :

- llama-swap : liste des modèles, discussion, bascule entre les deux gros modèles, embeddings, rerank ;
- OmniRoute : préconfiguration automatique sur une instance neuve, discussion par chaque combo ;
- Goose, jcode, OpenCode et Open Code Review à travers la passerelle, avec leurs fichiers générés ;
- les trois serveurs MCP (NixOS, Engram, Qdrant) ;
- Open WebUI : démarrage sans mot de passe, discussion, recherche web par SearXNG, indexation dans Qdrant.

À tester chez toi (`[?]` dans les fichiers) :

- le modèle principal sur 16 Go de VRAM : ajuster `--n-cpu-moe` dans `parametres.nix` ;
- le moteur ROCm (`moteurGPU = "rocm"`) ;
- Vane et Cognee (`actif.vane`, `actif.cognee`) ;
- la boucle de nuit de bout en bout ;
- Feynman : il demande son propre `feynman setup` au premier lancement.

## Non installé

- **Goose Desktop** (7.4) et **Paperclip** (4.9) : pas de paquet NixOS.
- **Axolotl / Unsloth** (1.6) : phase 4 de la flowchart, à faire modèle déchargé.
- **sops-nix** (0.3) : remplacé par des secrets générés sur place, voir `systeme/socle.nix`.
- **Catalogues** (8.6) : ce sont des listes à consulter, rien à installer.
  awesome-mcp-servers, awesome-llm-apps, public-apis. ECC : dépôt introuvable sous le nom que j'avais.
- **Réserve** (niveau R) : Switchyard, OpenObserve, AppFlowy, Orca.

## Monter de version

- Outils compilés et skills : changer le numéro dans `flake.nix` (et dans `versions` de `parametres.nix`). Pour Engram et ocr, Nix affichera une nouvelle empreinte à recopier dans `paquets.nix`.
- OmniRoute, Feynman, anydoc, Graphify, Cognee : changer le numéro dans `versions`.
