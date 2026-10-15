# IA — partie UTILISATEUR (home-manager) : niveaux 4, 5 et 8 de la flowchart.
# Agents, serveurs MCP et skills. Activée par la ligne ./IA/home.nix dans home.nix.
#
# Principe du maillage : la porte, le modèle, les serveurs MCP et les skills sont
# définis UNE fois ici, puis distribués à chaque agent dans son propre format.
# Ajouter un serveur MCP dans "mcp" ci-dessous le donne à Goose, jcode et OpenCode.
#
# Conséquence : les fichiers de configuration des agents sont en lecture seule.
# Un réglage changé depuis l'interface d'un agent ne sera pas enregistré : c'est voulu,
# la référence est ce fichier.
{ config, pkgs, lib, inputs, ... }:

let
  ia = import ./parametres.nix;
  paquets = import ./paquets.nix { inherit pkgs lib inputs; p = ia; };

  # ---------------------------------------------------------------------------
  # 5.2 Serveurs MCP, communs à tous les agents
  # ---------------------------------------------------------------------------
  mcp = {
    # Indispensable : options NixOS, paquets, Home Manager — l'agent arrête d'inventer.
    nixos = {
      command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
      args = [ ];
      env = { };
      description = "Options et paquets NixOS / Home Manager";
    };
    # 2.3 Mémoire des agents : décisions et préférences, gardées d'une session à l'autre
    engram = {
      command = "${paquets.engram}/bin/engram";
      args = [ "mcp" "--tools=agent" ];
      env = { };
      description = "Mémoire persistante des agents (Engram)";
    };
  } // lib.optionalAttrs ia.actif.qdrant {
    # 2.1 Base vectorielle partagée [?] (télécharge un petit modèle d'embeddings au 1er usage)
    qdrant = {
      command = "${paquets.mcp-qdrant}/bin/mcp-server-qdrant";
      args = [ ];
      env = {
        QDRANT_URL = ia.url.qdrant;
        COLLECTION_NAME = "memoire-agents";
      };
      description = "Recherche sémantique dans Qdrant";
    };
  };

  # ---------------------------------------------------------------------------
  # 8.3 à 8.5 Skills retenus : nom installé -> chemin dans la source
  # ---------------------------------------------------------------------------
  # Les sources sont épinglées dans flake.nix. Les hooks et scripts d'installation
  # des dépôts ne sont PAS exécutés (0.6) : seuls les dossiers de skills sont copiés.
  skills = {
    pocock = { # 8.3 Questions d'abord
      grill-me = "productivity/grill-me";
      grill-with-docs = "engineering/grill-with-docs";
      diagnose = "engineering/diagnosing-bugs";
      handoff = "productivity/handoff";
      to-spec = "engineering/to-spec";
      to-tickets = "engineering/to-tickets";
    };
    osmani = { # 8.4 Méthode de travail : spec -> plan -> build -> test -> review -> ship
      spec = "spec-driven-development";
      plan = "planning-and-task-breakdown";
      build = "incremental-implementation";
      test = "test-driven-development";
      review = "code-review-and-quality";
      ship = "shipping-and-launch";
    };
    archify.archify = "archify"; # 7.6 schémas (JSON validé -> HTML)
    last30days.last30days = "last30days"; # 6.5 veille 30 jours
    anydoc.anydoc = "convert-documents-to-markdown"; # 6.3 documents -> Markdown
    engram.engram-memoire = "memory-protocol"; # 2.3 quand et comment l'agent doit mémoriser
    ocr.open-code-review = "open-code-review"; # 4.6 relecture avant commit
  };

  # ---------------------------------------------------------------------------
  # Pour claude-local : serveurs MCP (format de Claude Code) et consignes ajoutées
  claudeMcp = pkgs.writeText "claude-local-mcp.json" (builtins.toJSON {
    mcpServers = lib.mapAttrs (_: s: { inherit (s) command args env; }) mcp;
  });
  consignesLocales = ''
    Tu tournes sur une IA locale, sans accès aux serveurs d'Anthropic.
    RECHERCHE SUR INTERNET : l'outil WebSearch n'existe pas ici. Pour chercher, lance avec Bash :
      curl -sG "${ia.url.searxng}/search" --data-urlencode format=json --data-urlencode "q=tes mots clés" | jq -r '.results[:8][] | "\(.title) | \(.url)\n\(.content)\n"'
    Puis lis les pages utiles avec WebFetch ou :
      curl -sL "ADRESSE" | sed 's/<[^>]*>//g' | tr -s ' \n' | head -c 20000
    Cite toujours les adresses de tes sources.
    MÉMOIRE : les outils mem_* (Engram) gardent tes découvertes et décisions d'une session à
    l'autre. Enregistre ce qui servira plus tard ; consulte-les au début d'une tâche.
    Pour une longue recherche, écris tes résultats au fur et à mesure dans un fichier du
    dossier courant, pour ne rien perdre.
  '';
  # ---------------------------------------------------------------------------
  # Claude Code piloté par l'IA LOCALE (au lieu d'Opus dans le cloud)
  # ---------------------------------------------------------------------------
  # OmniRoute comprend le format de Claude Code : il suffit de lui indiquer l'adresse de
  # la passerelle. Vérifié : Claude Code a créé un module et ses tests, tous réussis, avec
  # toutes les requêtes servies par le moteur local.
  #   claude-local                 session interactive, comme "claude"
  #   claude-local -p "consigne"   une consigne, sans interaction
  claudeLocal = pkgs.writeShellScriptBin "claude-local" ''
    cle=$(cut -d= -f2- ${ia.cleFichier} 2>/dev/null) || {
      echo "Clé de la passerelle illisible (${ia.cleFichier})." >&2; exit 1; }
    export ANTHROPIC_BASE_URL=${lib.removeSuffix "/v1" ia.porteUrl}
    export ANTHROPIC_AUTH_TOKEN="$cle"
    export ANTHROPIC_MODEL=${ia.modeleParDefaut}
    export ANTHROPIC_DEFAULT_HAIKU_MODEL=${ia.modeleParDefaut}
    export ANTHROPIC_DEFAULT_SONNET_MODEL=${ia.modeleParDefaut}
    export ANTHROPIC_DEFAULT_OPUS_MODEL=${ia.modeleParDefaut}
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export DISABLE_AUTOUPDATER=1
    export DISABLE_TELEMETRY=1
    # Un modèle local réfléchit longtemps avant d'écrire : délai de réponse allongé
    export API_TIMEOUT_MS=3600000
    # Taille réelle de la mémoire de travail du modèle local (par agent) : sans ce réglage,
    # Claude Code croit en avoir 200 000 jetons et finirait par envoyer des demandes refusées.
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS=${toString (ia.modeles.principal.contexte)}
    # Réponses limitées à 16 000 jetons : le reste de la mémoire de travail sert à la lecture
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000
    # Outils utilisés par l'agent pour chercher et lire sur Internet
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.gnused ]}:$PATH
    # Internet : la "recherche web" intégrée à Claude Code passe par les serveurs d'Anthropic,
    # inaccessibles avec l'IA locale. Elle est donc désactivée, et l'agent utilise à la place
    # ton moteur de recherche local (SearXNG), puis WebFetch pour lire les pages trouvées.
    # Mémoire : serveurs MCP partagés avec les autres agents (Engram, NixOS, Qdrant).
    exec ${pkgs.claude-code}/bin/claude \
      --mcp-config ${claudeMcp} \
      --disallowedTools WebSearch \
      --append-system-prompt ${lib.escapeShellArg consignesLocales} \
      "$@"
  '';

  # ---------------------------------------------------------------------------
  # nuit "consigne" : l'IA locale travaille seule dans le projet courant, aussi longtemps
  # qu'il le faut (toute la nuit si besoin).
  # ---------------------------------------------------------------------------
  # - travaille sur une branche Git à part "nuit/<date>", ne pousse rien ;
  # - tourne en arrière-plan : tu peux fermer VS Code ou le terminal ;
  # - empêche la mise en veille de l'ordinateur tant qu'elle travaille ;
  # - journal complet dans ${ia.dossier}/agents/nuit/ ; notification à la fin.
  # Arrêter : nuit --stop        Suivre en direct : nuit --suivre
  nuit = pkgs.writeShellScriptBin "nuit" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.libnotify pkgs.systemd ]}:$PATH
    journaux=${ia.dossier}/agents/nuit
    case "''${1:-}" in
      --stop) systemctl --user stop 'nuit-*' && echo "Travail de nuit arrêté."; exit 0 ;;
      --suivre) exec tail -f "$(ls -t "$journaux"/*.log | head -1)" ;;
      ""|-h|--help)
        echo "usage : nuit \"ce que l'IA doit faire\"   (dans le dossier du projet)"
        echo "        nuit --suivre | nuit --stop"; exit 0 ;;
    esac
    consigne="$*"
    projet=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "Lance nuit depuis un dossier de projet Git (ou fais d'abord : git init)." >&2; exit 1; }
    cd "$projet"
    nom="nuit-$(date +%Y%m%d-%H%M%S)"
    git switch -q -c "nuit/''${nom#nuit-}" 2>/dev/null || true
    mkdir -p "$journaux"
    journal="$journaux/$nom.log"

    systemd-run --user --unit="$nom" --collect --same-dir \
      --property=MemoryHigh=${ia.memoireMax.nuit} --property=Nice=5 \
      ${pkgs.bash}/bin/bash -c '
        consigne="$1"; journal="$2"
        {
          echo "=== $(date) — $PWD"; echo "Consigne : $consigne"; echo
          systemd-inhibit --what=sleep --who="IA de nuit" --why="Travail en cours" \
            ${claudeLocal}/bin/claude-local -p "$consigne

Tu travailles seul, sans personne pour répondre à tes questions : prends les décisions
raisonnables toi-même. Avance par petites étapes, lance les tests du projet après chaque
étape, et fais un commit Git à chaque étape réussie. Ne pousse rien, n installe rien sur
le système. Termine par un résumé de ce qui a été fait et de ce qui reste." \
            --dangerously-skip-permissions --max-turns 500 --output-format text
          code=$?
          echo; echo "=== Fin : $(date) (code $code)"
        } >"$journal" 2>&1
        notify-send -a "IA de nuit" "Travail terminé" "$(tail -n 3 "$journal")"
      ' _ "$consigne" "$journal" >/dev/null

    echo "L'IA locale travaille dans : $projet (branche nuit/''${nom#nuit-})"
    echo "Journal : $journal"
    echo "Suivre : nuit --suivre     Arrêter : nuit --stop"
  '';
in
{
  imports = [ inputs.agent-skills.homeManagerModules.default ];

  # ---------------------------------------------------------------------------
  # Outils en ligne de commande
  # ---------------------------------------------------------------------------
  home.packages = [
    claudeLocal # Claude Code sur l'IA locale     -> claude-local
    nuit # travail autonome de longue durée     -> nuit "consigne"
    pkgs.goose-cli # 4.1 agent principal            -> goose
    pkgs.opencode # 4.2 plan B                      -> opencode
    pkgs.beads # 4.3 file de tâches                 -> bd
    paquets.ocr # 4.6 relecture de code             -> ocr
    paquets.engram # 2.3 mémoire des agents         -> engram
    paquets.graphify # 2.4 carte du code et des docs -> graphify
    pkgs.spider # 6.2 collecte de pages web         -> spider
    paquets.anydoc # 6.3 documents -> Markdown      -> anydoc
    paquets.feynman # 6.4 recherche approfondie     -> feynman
    pkgs.mcp-nixos # 5.2
    pkgs.uv # lance les outils Python des skills (last30days...)
    pkgs.nodejs_24 # lance les outils npm
  ] ++ lib.optional ia.actif.jcode paquets.jcode; # 4.2 second agent -> jcode

  # ---------------------------------------------------------------------------
  # Données des agents : rangées dans le dossier central (parametres.nix : dossier)
  # ---------------------------------------------------------------------------
  # Les agents écrivent à leur emplacement habituel dans ton dossier personnel ;
  # ces raccourcis redirigent vers le dossier central, où tout est regroupé.
  home.file.".engram".source = config.lib.file.mkOutOfStoreSymlink "${ia.dossier}/agents/engram"; # 2.3 mémoire
  xdg.dataFile."goose".source = config.lib.file.mkOutOfStoreSymlink "${ia.dossier}/agents/goose"; # 4.1 sessions

  # ---------------------------------------------------------------------------
  # La porte, pour tout programme lancé depuis ta session
  # ---------------------------------------------------------------------------
  # L'adresse et la clé sont fournies à toute ta session par IA/systeme/socle.nix
  # (variables OPENAI_BASE_URL et OPENAI_API_KEY) : les agents ci-dessous les lisent.


  # VS Code : deux tâches prêtes à l'emploi (Ctrl+Maj+P > "Exécuter la tâche").
  #   "IA locale : travailler seule (nuit)"   demande la consigne puis lance nuit
  #   "IA locale : suivre le travail"         affiche le journal en direct
  home.file.".config/Code/User/tasks.json".text = builtins.toJSON {
    version = "2.0.0";
    tasks = [
      {
        label = "IA locale : travailler seule (nuit)";
        type = "shell";
        command = "nuit \"\${input:consigne}\"";
        options.cwd = "\${workspaceFolder}";
        problemMatcher = [ ];
      }
      {
        label = "IA locale : suivre le travail";
        type = "shell";
        command = "nuit --suivre";
        problemMatcher = [ ];
      }
      {
        label = "IA locale : arrêter le travail";
        type = "shell";
        command = "nuit --stop";
        problemMatcher = [ ];
      }
    ];
    inputs = [{
      id = "consigne";
      type = "promptString";
      description = "Ce que l'IA locale doit faire dans ce projet (elle travaille seule, sur une branche à part)";
    }];
  };
  # ---------------------------------------------------------------------------
  # 4.1 Goose : agent principal
  # ---------------------------------------------------------------------------
  xdg.configFile."goose/config.yaml".text = builtins.toJSON {
    GOOSE_PROVIDER = "openai";
    GOOSE_MODEL = ia.modeleParDefaut;
    OPENAI_HOST = lib.removeSuffix "/v1" ia.porteUrl;
    OPENAI_BASE_PATH = "v1/chat/completions";
    GOOSE_TELEMETRY_ENABLED = false;

    extensions = {
      # Outils intégrés : lire/écrire des fichiers, lancer des commandes
      developer = {
        enabled = true;
        type = "builtin";
        name = "developer";
        timeout = 300;
      };
    } // lib.mapAttrs (nom: s: {
      enabled = true;
      type = "stdio";
      name = nom;
      cmd = s.command;
      args = s.args;
      envs = s.env;
      description = s.description;
      timeout = 300;
    }) mcp;
  }; # (le JSON est du YAML valide : Goose le lit tel quel)

  # ---------------------------------------------------------------------------
  # 4.2 jcode : second agent (essaims)
  # ---------------------------------------------------------------------------
  home.file.".jcode/config.toml" = lib.mkIf ia.actif.jcode {
    source = (pkgs.formats.toml { }).generate "jcode-config.toml" {
      provider = {
        default_provider = "local";
        default_model = ia.modeleParDefaut;
      };
      providers.local = {
        type = "openai-compatible";
        base_url = ia.porteUrl;
        api_key_env = "OPENAI_API_KEY"; # lue dans ta session, jamais écrite ici
        default_model = ia.modeleParDefaut;
        # 4.4 Deux agents en parallèle se partagent le contexte du modèle local
        models = map (nom: { id = nom; context_window = ia.modeles.principal.contexte; }) ia.modelesProposes;
      };
    };
  };
  home.file.".jcode/mcp.json" = lib.mkIf ia.actif.jcode {
    text = builtins.toJSON {
      mcpServers = lib.mapAttrs (_: s: { inherit (s) command args env; }) mcp;
    };
  };

  # ---------------------------------------------------------------------------
  # 4.2 OpenCode : plan B
  # ---------------------------------------------------------------------------
  xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    autoupdate = false;
    share = "disabled";
    model = "local/${ia.modeleParDefaut}";
    provider.local = {
      npm = "@ai-sdk/openai-compatible";
      name = "Porte locale";
      options = {
        baseURL = ia.porteUrl;
        apiKey = "{env:OPENAI_API_KEY}"; # lue dans ta session, jamais écrite ici
      };
      models = lib.genAttrs ia.modelesProposes (nom: { name = nom; });
    };
    mcp = lib.mapAttrs (_: s: {
      type = "local";
      command = [ s.command ] ++ s.args;
      environment = s.env;
      enabled = true;
    }) mcp;
  };

  # ---------------------------------------------------------------------------
  # 4.6 Open Code Review : relecture avant commit, branchée sur la porte
  # ---------------------------------------------------------------------------
  home.file.".opencodereview/config.json".text = builtins.toJSON {
    provider = "porte";
    custom_providers.porte = {
      url = ia.porteUrl;
      protocol = "openai";
      model = ia.modeleParDefaut;
      api_key_cmd = "cut -d= -f2- ${ia.cleFichier}"; # lit la clé dans le dossier des secrets
    };
    llm = { };
  };

  # ---------------------------------------------------------------------------
  # 8.1, 8.2 Skills : un dossier commun, distribué à chaque agent
  # ---------------------------------------------------------------------------
  programs.agent-skills = {
    enable = true;

    sources = {
      pocock = { path = inputs.skills-pocock; subdir = "skills"; };
      osmani = { path = inputs.skills-osmani; subdir = "skills"; };
      archify = { path = inputs.skills-archify; subdir = "."; filter.maxDepth = 1; };
      last30days = { path = inputs.skills-last30days; subdir = "skills"; };
      anydoc = { path = inputs.anydoc-src; subdir = "skills"; };
      engram = { path = inputs.engram-src; subdir = "skills"; };
      ocr = { path = inputs.ocr-src; subdir = "skills"; };
    };

    # Transforme la liste "skills" du haut du fichier dans le format du module.
    skills.explicit = lib.concatMapAttrs
      (source: liste: lib.mapAttrs (_: chemin: { from = source; path = chemin; }) liste)
      skills;

    targets = {
      agents.enable = true; # ~/.agents/skills : dossier commun, lu par Goose
      opencode.enable = true; # ~/.config/opencode/skills
    } // lib.optionalAttrs ia.actif.jcode {
      # jcode lit ~/.jcode/skills (vérifié dans son code source)
      jcode = {
        enable = true;
        dest = "$HOME/.jcode/skills";
        structure = "symlink-tree";
      };
    };
  };
}
