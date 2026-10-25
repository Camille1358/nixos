# NIVEAUX 6 et 7 : recherche web et interfaces graphiques.
# Chaque interface est branchée ici sur la porte, la recherche et la base vectorielle :
# il n'y a rien à régler dans les applications elles-mêmes.
{ config, pkgs, lib, ia, inputs, iaPaquets, iaCompte, ... }:

{
  # ---------------------------------------------------------------------------
  # 6.1 Recherche web : SearXNG
  # ---------------------------------------------------------------------------
  # Le format JSON est indispensable : c'est lui que lisent Open WebUI, Vane et les agents.
  # Pas de limiteur de débit (ni donc de Redis) : il ne sert que pour un service exposé
  # sur Internet, or celui-ci n'écoute que sur cette machine.
  services.searx = lib.mkIf ia.actif.searxng {
    enable = true;
    redisCreateLocally = false;
    environmentFile = "${ia.dossier}/secrets/searxng.env"; # fournit SEARXNG_SECRET
    settings = {
      server = {
        bind_address = ia.hote;
        port = ia.ports.searxng;
        secret_key = "$SEARXNG_SECRET";
        limiter = false;
      };
      search = {
        safe_search = 0;
        formats = [ "html" "json" ];
      };
      outgoing.request_timeout = 6.0;
      # Moteurs testés un par un le 25/10/2026, depuis ta connexion :
      #   répondent : Bing, GitHub, Stack Overflow (ces deux-là : précieux pour les recherches
      #               techniques, API, code) ; Wikipédia et Wikidata (culture générale) ;
      #   bloqués   : DuckDuckGo (CAPTCHA), Brave (trop de requêtes), Startpage (plantage),
      #               Qwant et Presearch (accès refusé), Yahoo (erreur), Reddit (accès refusé) ;
      #   muets     : Google et Mojeek (aucun résultat, sans erreur).
      # Avant, seul Bing répondait : une recherche technique ne renvoyait que des pages
      # génériques, et chaque moteur bloqué faisait attendre jusqu'à 6 s. Les bloqués et les
      # muets sont donc coupés. À retester de temps en temps : un blocage peut se lever.
      engines =
        map (nom: { name = nom; disabled = false; }) [ "bing" "github" "stackoverflow" "wikipedia" "wikidata" ]
        ++ map (nom: { name = nom; disabled = true; }) [
          "google" "mojeek" "duckduckgo" "brave" "startpage" "qwant" "yahoo" "presearch" "reddit"
        ];
    };
  };
  systemd.services.searx = lib.mkIf ia.actif.searxng {
    after = [ "ia-secrets.service" ];
    requires = [ "ia-secrets.service" ];
    serviceConfig.Slice = "ia.slice";
  };
  # Le service de préparation de SearXNG lit le même fichier de secrets : sans cette attente,
  # il démarrait avant sa création et échouait (constaté au premier démarrage).
  systemd.services.searx-init = lib.mkIf ia.actif.searxng {
    after = [ "ia-secrets.service" ];
    requires = [ "ia-secrets.service" ];
  };

  # ---------------------------------------------------------------------------
  # 7.1 Chat et RAG : Open WebUI
  # ---------------------------------------------------------------------------
  services.open-webui = lib.mkIf ia.actif.openWebui {
    enable = true;
    host = ia.hote;
    port = ia.ports.openWebui;
    stateDir = "${ia.dossier}/services/open-webui";
    # L'Open WebUI de nixpkgs est livré sans le module qui parle à Qdrant : sans cet ajout,
    # il plante au démarrage dès que VECTOR_DB = "qdrant" (constaté en essai réel).
    # Contrepartie : Open WebUI est recompilé sur ta machine au lieu d'être téléchargé.
    package = pkgs.open-webui.overridePythonAttrs (old: {
      dependencies = (old.dependencies or [ ]) ++ [ pkgs.python3Packages.qdrant-client ];
    });
    environmentFile = "${ia.dossier}/secrets/open-webui.env"; # fournit WEBUI_SECRET_KEY
    environment = {
      # Sans cette ligne, Open WebUI ne lit ces variables qu'au tout premier lancement puis
      # garde ses réglages dans sa base : avec, ce fichier Nix reste la seule référence.
      ENABLE_PERSISTENT_CONFIG = "False";

      # Un seul utilisateur, en local : pas d'écran de connexion.
      WEBUI_AUTH = "False";

      # Modèles : la porte (parametres.nix). Ollama n'est pas utilisé.
      ENABLE_OLLAMA_API = "False";
      ENABLE_OPENAI_API = "True";
      OPENAI_API_BASE_URL = ia.porteUrl;
      # (OPENAI_API_KEY est lue dans le dossier des secrets : voir EnvironmentFile plus bas)
      DEFAULT_MODELS = ia.modeleParDefaut;

      # 6.1 Recherche web par SearXNG
      ENABLE_WEB_SEARCH = "True";
      WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "${ia.url.searxng}/search?q=<query>&format=json";
      WEB_SEARCH_RESULT_COUNT = "5";

      # 2.1 Documents (RAG) : vecteurs dans Qdrant, embeddings par le moteur local (1.5, 3.4)
      VECTOR_DB = "qdrant";
      QDRANT_URI = ia.url.qdrant;
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_OPENAI_API_BASE_URL = ia.embeddingsUrl;
      RAG_OPENAI_API_KEY = ia.cleLocale;
      RAG_EMBEDDING_MODEL = ia.modeles.embeddings.nom;
      # Envoie les textes par paquets, l'un après l'autre, au lieu de tout en même temps.
      RAG_EMBEDDING_BATCH_SIZE = "16";
      ENABLE_ASYNC_EMBEDDING = "False";

      # 0.5 Télémétrie coupée
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };
  systemd.services.open-webui = lib.mkIf ia.actif.openWebui {
    # Attend la préconfiguration d'OmniRoute : c'est elle qui crée la clé lue ci-dessous.
    after = [ "ia-secrets.service" "qdrant.service" "llama-swap.service" "omniroute-init.service" ];
    requires = [ "ia-secrets.service" ];
    wants = lib.optional (ia.porte == "omniroute") "omniroute-init.service";
    serviceConfig = {
      # Deux fichiers de secrets : la clé interne d'Open WebUI, et la clé de la porte.
      EnvironmentFile = lib.mkForce [ "${ia.dossier}/secrets/open-webui.env" "-${ia.cleFichier}" ];
      Slice = "ia.slice";
      MemoryMax = ia.memoireMax.openWebui;
      Restart = lib.mkForce "always";
    } // iaCompte "services/open-webui";
  };

  # ---------------------------------------------------------------------------
  # 7.2 Réponses citées : Vane (ex-Perplexica) [?]
  # ---------------------------------------------------------------------------
  # Pas de paquet Nix ni d'installation sans compilation : le code (épinglé dans flake.nix)
  # est copié puis compilé dans ${ia.dossier}/services/vane au premier démarrage, et à chaque changement
  # de version. Vane n'a aucune authentification : il n'écoute que sur cette machine.
  systemd.services.vane = lib.mkIf ia.actif.vane {
    description = "IA 7.2 : Vane (réponses citées)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "searx.service" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.nodejs_24 pkgs.yarn pkgs.python3 pkgs.gcc pkgs.gnumake pkgs.coreutils pkgs.git ];
    environment = {
      HOME = "${ia.dossier}/services/vane";
      DATA_DIR = "${ia.dossier}/services/vane";
      NODE_ENV = "production";
      LD_LIBRARY_PATH = iaPaquets.libs;
      NEXT_TELEMETRY_DISABLED = "1";
      PORT = toString ia.ports.vane;
      HOSTNAME = ia.hote;

      SEARXNG_API_URL = ia.url.searxng;
      OPENAI_BASE_URL = ia.porteUrl;
    };

    preStart = ''
      if [ "$(cat .version 2>/dev/null)" != "${ia.versions.vane}" ]; then
        echo "Compilation de Vane ${ia.versions.vane} (quelques minutes)..."
        rm -rf app
        cp -r ${inputs.vane-src} app
        chmod -R u+w app
        cd app
        yarn install --frozen-lockfile --network-timeout 600000
        NODE_ENV=production yarn build
        cd ..
        echo "${ia.versions.vane}" > .version
      fi
      mkdir -p data uploads
    '';

    serviceConfig = {
      ExecStart = "${pkgs.yarn}/bin/yarn --cwd ${ia.dossier}/services/vane/app start --hostname ${ia.hote} --port ${toString ia.ports.vane}";
      EnvironmentFile = "-${ia.cleFichier}"; # fournit OPENAI_API_KEY (Vane refuse un champ vide)
      Slice = "ia.slice";
      WorkingDirectory = "${ia.dossier}/services/vane";
      MemoryMax = ia.memoireMax.vane;
      Restart = "always";
      RestartSec = 30;
      TimeoutStartSec = "30min";
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
    } // iaCompte "services/vane";
  };

  # ---------------------------------------------------------------------------
  # 7.5 Intégrations (option) : n8n — mail, Telegram, webhooks
  # ---------------------------------------------------------------------------
  # La planification elle-même n'en a pas besoin (voir systeme/nuit.nix).
  services.n8n = lib.mkIf ia.actif.n8n {
    enable = true;
    environment = {
      N8N_PORT = toString ia.ports.n8n;
      N8N_LISTEN_ADDRESS = ia.hote;
      N8N_DIAGNOSTICS_ENABLED = "false"; # 0.5
      N8N_VERSION_NOTIFICATIONS_ENABLED = "false";
    };
  };
}
