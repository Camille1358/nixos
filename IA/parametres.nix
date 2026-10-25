# =============================================================================
# IA — TABLEAU DE BORD : le seul fichier à modifier au quotidien.
# =============================================================================
# Tous les autres fichiers du dossier IA/ lisent leurs valeurs ici : ports,
# modèles, versions, interrupteurs. Changer un port ou un modèle ici le change
# partout d'un coup (services, agents, interfaces) : c'est le "maillage".
#
# Après modification : nrsf
#
# Les numéros (1.2, 3.1, ...) renvoient aux lignes de la flowchart v6.
# [?] = non vérifié sur ta machine, à tester.
# =============================================================================
rec {
  # ---------------------------------------------------------------------------
  # INTERRUPTEURS : true = installé et démarré ; false = absent du système
  # ---------------------------------------------------------------------------
  actif = {
    # Testés à la compilation (modules NixOS natifs)
    inference = true; # 1.x llama-swap + llama.cpp + téléchargement des modèles
    qdrant = true; # 2.1 base vectorielle
    searxng = true; # 6.1 recherche web
    openWebui = true; # 7.1 chat et RAG
    omniroute = true; # 3.1 passerelle local + cloud

    # Installés par npm / pip au premier démarrage [?]
    vane = false; # 7.2 réponses citées (compilé au 1er démarrage : ~5 min)
    cognee = false; # 2.2 mémoire de savoir (graphe embarqué)

    # Options de la flowchart
    jcode = true; # 4.2 second agent (long à compiler la première fois)
    boucleDeNuit = false; # 4.5 mets true APRÈS avoir rempli "nuit.projets" plus bas
    tailscale = false; # 0.3 accès distant (demande une connexion à ton compte Tailscale)
    n8n = false; # 7.5 intégrations (mail, Telegram, webhooks)
  };

  # ---------------------------------------------------------------------------
  # DOSSIER CENTRAL : tout ce que l'IA écrit sur le disque est ici, et nulle part ailleurs
  # ---------------------------------------------------------------------------
  #   modeles/    les fichiers de modèles (.gguf), ~28 Go
  #   services/   les données de chaque service (Open WebUI, Qdrant, OmniRoute, Cognee, Vane)
  #   agents/     la mémoire et l'historique des agents (Engram, Goose, journaux de nuit)
  #   outils/     les outils téléchargés à la demande (npm, Python)
  #   cache/      fichiers temporaires du moteur (supprimables)
  #   secrets/    mots de passe et clés générés automatiquement
  # Sauvegarder l'IA = copier ce dossier. Repartir de zéro = le supprimer.
  #
  # Il doit être sur un disque au format Linux (ext4) : /storage/NVME est en NTFS, un
  # format Windows qui ne gère pas les droits dont les services ont besoin.
  # Si tu changes ce chemin plus tard, déplace le dossier toi-même avant de lancer nrs.
  dossier = "/storage/IA";

  # ---------------------------------------------------------------------------
  # RÉSEAU (0.3) : tout écoute sur cette machine uniquement
  # ---------------------------------------------------------------------------
  hote = "127.0.0.1";

  ports = {
    openWebui = 8080;
    llamaSwap = 8081;
    cognee = 8000;
    vane = 3000;
    n8n = 5678;
    qdrant = 6333;
    qdrantGrpc = 6334;
    searxng = 8888;
    omniroute = 20128;
  };

  # Adresses complètes, calculées à partir des ports (ne pas modifier)
  url = {
    llamaSwap = "http://${hote}:${toString ports.llamaSwap}/v1";
    omniroute = "http://${hote}:${toString ports.omniroute}/v1";
    omnirouteTableau = "http://${hote}:${toString ports.omniroute}";
    qdrant = "http://${hote}:${toString ports.qdrant}";
    searxng = "http://${hote}:${toString ports.searxng}";
    cognee = "http://${hote}:${toString ports.cognee}";
    openWebui = "http://${hote}:${toString ports.openWebui}";
    vane = "http://${hote}:${toString ports.vane}";
  };

  # ---------------------------------------------------------------------------
  # LA PORTE (3.x) : à quelle adresse parlent TOUS les outils (agents, interfaces)
  # ---------------------------------------------------------------------------
  # "omniroute"  = la passerelle (flowchart 3.1) : local d'abord, cloud en repli.
  #                Elle est préconfigurée automatiquement au premier démarrage
  #                (systeme/passerelle.nix) : le moteur local y est déclaré, les combos
  #                ci-dessous créés, et une clé générée pour tes outils.
  # "llama-swap" = directement le moteur local, sans passerelle. Solution de secours si
  #                OmniRoute pose problème : change ce mot, nrs, et tout repart.
  porte = "omniroute";

  # 3.2 Combos créés dans OmniRoute : nom -> modèles essayés dans l'ordre.
  # Tes outils demandent un combo par son nom, comme si c'était un modèle.
  # Pour le repli vers le cloud : ajoute tes comptes dans le tableau de bord d'OmniRoute
  # (c'est la seule chose que Nix ne peut pas faire à ta place : ce sont tes identifiants),
  # puis ajoute leurs modèles à la fin de ces listes sous la forme "fournisseur/modèle".
  combos = {
    local-first = [ "openai-compatible/${modeles.principal.nom}" "openai-compatible/${modeles.repli.nom}" ];
    nuit = [ "openai-compatible/${modeles.principal.nom}" "openai-compatible/${modeles.repli.nom}" ];
  };

  # Adresse réellement donnée aux outils (ne pas modifier)
  porteUrl = if porte == "omniroute" then url.omniroute else url.llamaSwap;
  # 3.4 Chemin court : les embeddings vont toujours directement au moteur local.
  embeddingsUrl = url.llamaSwap;

  # Clés (ne pas modifier). Le moteur local n'en exige pas, mais beaucoup d'outils
  # refusent un champ vide : d'où le mot "local". OmniRoute, lui, exige une vraie clé,
  # générée automatiquement et rangée dans le dossier central. Les outils lisent la bonne
  # dans ce fichier : aucune clé n'est écrite dans /etc/nixos ni dans le magasin Nix.
  cleLocale = "local";
  cleFichier = "${dossier}/secrets/${if porte == "omniroute" then "cle-omniroute.env" else "cle-locale.env"}";

  # ---------------------------------------------------------------------------
  # MOTEUR (0.1, 1.1)
  # ---------------------------------------------------------------------------
  # "vulkan" = Mesa RADV : paquet précompilé, marche d'office sur la RX 6800 XT.
  # "rocm"   = ROCm/HIP (gfx1030) : parfois plus rapide, mais plus fragile. [?]
  # La flowchart demande de tester les deux : change ce mot, nrsf, compare les jetons/s.
  moteurGPU = "vulkan";

  # Carte graphique utilisée par le moteur, désignée par son identifiant matériel (constructeur:
  # modèle), qui ne change jamais : 1002:73bf = la RX 6800 XT. Le moteur ne voit QU'ELLE, sous
  # le nom Vulkan0. (Avant, "Vulkan0" désignait la première carte trouvée : après un redémarrage
  # le 25/10/2026, c'était devenu la puce graphique du processeur, très lente.)
  # Vérifier : MESA_VK_DEVICE_SELECT=1002:73bf MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1 llama-server --list-devices
  carteVulkanId = "1002:73bf";
  carteVulkan = "Vulkan0";

  # ---------------------------------------------------------------------------
  # MODÈLES (1.3 à 1.5) — téléchargés automatiquement dans /var/lib/ia/modeles
  # ---------------------------------------------------------------------------
  # nom      : le nom à utiliser dans les outils
  # depot    : dépôt Hugging Face ; fichier : le .gguf à prendre dedans
  # options  : options passées à llama-server
  modeles = {
    # 1.3 Modèle principal — 16,5 Go : dépasse légèrement les 16 Go de VRAM, d'où
    # --n-cpu-moe (les "experts" MoE des premières couches restent en RAM). [?]
    # Monte ce nombre si le chargement échoue faute de VRAM, baisse-le pour aller plus vite.
    principal = {
      nom = "qwen3.6-35b";
      depot = "unsloth/Qwen3.6-35B-A3B-GGUF";
      fichier = "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
      # Mémoire de travail : 65 536 jetons, pour UN agent à la fois (-np 1). Les agents de code
      # en ont besoin (Claude Code seul en occupe ~10 000) ; un 2e agent attend son tour.
      contexte = 65536;
      options = "-ngl 99 --n-cpu-moe 8 -np 1 -fa on --cache-type-k q8_0 --cache-type-v q8_0 --jinja";
    };

    # 1.4 Modèle de repli — tient entièrement en VRAM, rapide
    repli = {
      nom = "gpt-oss-20b";
      depot = "unsloth/gpt-oss-20b-GGUF";
      fichier = "gpt-oss-20b-Q4_K_M.gguf";
      contexte = 32768;
      options = "-ngl 99 -np 2 -fa on --jinja";
    };

    # 1.5 Embeddings et rerank — sur le processeur : la VRAM reste au LLM
    embeddings = {
      nom = "embeddings";
      depot = "Qwen/Qwen3-Embedding-0.6B-GGUF";
      fichier = "Qwen3-Embedding-0.6B-Q8_0.gguf";
      dimensions = 1024;
      # 4 demandes en parallèle de 8 192 jetons chacune ; -b / -ub = taille maximale d'un texte
      contexte = 32768;
      options = "-ngl 0 -t 8 --embedding --pooling last -np 4 -b 8192 -ub 8192";
    };
    rerank = {
      nom = "rerank";
      depot = "gpustack/bge-reranker-v2-m3-GGUF";
      fichier = "bge-reranker-v2-m3-Q4_K_M.gguf";
      contexte = 32768;
      options = "-ngl 0 -t 8 --reranking -np 4 -b 8192 -ub 8192";
    };
  };

  # Modèle utilisé par défaut par les agents et les interfaces (ne pas modifier) :
  # le combo "local-first" via la passerelle, sinon le modèle principal en direct.
  modeleParDefaut = if porte == "omniroute" then "local-first" else modeles.principal.nom;
  modeleDeNuit = if porte == "omniroute" then "nuit" else modeles.principal.nom;
  # Noms proposés dans les listes de modèles des agents
  modelesProposes =
    (if porte == "omniroute" then builtins.attrNames combos else [ ])
    ++ (if porte == "omniroute" then [ ] else [ modeles.principal.nom modeles.repli.nom ]);

  # Un gros modèle inutilisé est déchargé après ce délai (libère la VRAM pour les jeux)
  dechargementApres = 900; # secondes

  # CHALEUR DE LA CARTE GRAPHIQUE pendant que l'IA travaille. Le 25/10/2026, un long travail
  # d'agents a fait monter la carte à 116 °C (point le plus chaud) : elle a éteint l'ordinateur
  # d'urgence. Baisser sa puissance ne suffit pas (elle refuse moins de 231 W) : on limite sa
  # fréquence tant qu'un modèle est chargé (programme llama-server), via LACT
  # (games_drivers.nix). Un modèle de langage dépend surtout de la mémoire de la carte, pas de
  # cette fréquence : il ralentit peu. En jeu (GameMode actif), la carte garde toute sa fréquence.
  # Fréquence d'origine : 2424 MHz. null = pas de limite.
  frequenceMaxCarteIA = 1800; # MHz

  # ---------------------------------------------------------------------------
  # MÉMOIRE PARTAGÉE (2.1, 2.3) : Engram (décisions, découvertes) et Qdrant (recherche par
  # le sens). Commune à tous les agents locaux ET à Claude Code (le Claude du cloud, dans
  # VS Code) : ce que l'un apprend, les autres le retrouvent.
  # ---------------------------------------------------------------------------
  memoire = {
    collection = "memoire-agents"; # collection Qdrant
    # Modèle qui transforme les textes en vecteurs : multilingue (français compris), 0,22 Go.
    # Le changer rend introuvables les souvenirs déjà rangés : il faudrait alors vider la
    # collection, puis relancer "memoire-conversations --tout".
    modele = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2";
    # Archive des conversations avec Claude Code (~/.claude/projects) : les nouveaux messages
    # sont ajoutés à Qdrant à cet intervalle, pour que l'IA locale retrouve ce qui a été dit.
    conversations = true;
    conversationsToutesLes = "30min";
  };

  # ---------------------------------------------------------------------------
  # ENDURANCE (0.4) : plafond de mémoire vive par service
  # ---------------------------------------------------------------------------
  # Un service qui dépasse son plafond est redémarré, au lieu de figer toute la machine.
  memoireMax = {
    llamaSwap = "26G"; # le LLM (experts MoE en RAM) + embeddings + rerank
    openWebui = "4G";
    omniroute = "6G"; # son installation par npm dépasse 3 Go (constaté)
    qdrant = "4G";
    cognee = "6G";
    vane = "3G";
    nuit = "8G";
  };

  # ---------------------------------------------------------------------------
  # BOUCLE DE NUIT (4.5 à 4.7)
  # ---------------------------------------------------------------------------
  nuit = {
    # Dossiers de projets Git sur lesquels l'agent a le droit de travailler la nuit.
    # Chaque projet doit contenir une file de tâches Beads (créée par "bd init").
    # Exemple : projets = [ "/home/host/Projets/mon-appli" ];
    projets = [ ];
    heure = "01:00"; # démarrage
    dureeMax = "6h"; # arrêt forcé au bout de ce temps
    tachesMax = 10; # nombre maximal de tâches par projet et par nuit
    # Commande de tests du projet (4.6). Vide = pas de tests, seulement la relecture ocr.
    tests = "";
  };

  # ---------------------------------------------------------------------------
  # VERSIONS FIGÉES (0.6) des outils absents de nixpkgs
  # ---------------------------------------------------------------------------
  # Les trois premières doivent correspondre aux versions épinglées dans flake.nix.
  versions = {
    engram = "3.4.0";
    ocr = "1.13.0";
    jcode = "0.95.0";
    vane = "1.12.2";
    omniroute = "3.8.51"; # [!] CVE-2026-88062 : garde cette version à jour
    feynman = "0.5.44";
    anydoc = "0.2.4";
    graphify = "0.9.89";
    cognee = "1.6.4";
    mcpQdrant = "0.8.1";
  };
}
