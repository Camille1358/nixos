{ config, pkgs, ... }:

let
  local = import ./local.nix;
  pkgs-stable-latest =
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz")
      {
        config.allowUnfree = true;
      };
  pkgs-unstable =
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz")
      {
        config.allowUnfree = true;
      };

  #-----------------------------------------------IA------------------------------------------------
  # 6.1 Dérivation personnalisée Nix pour Spider CLI via GitHub
  spider-cli = pkgs.rustPlatform.buildRustPackage rec {
    pname = "spider_cli";
    version = "2.2.0";

    src = pkgs.fetchFromGitHub {
      owner = "spider-rs";
      repo = "spider";
      rev = "v${version}";
      hash = pkgs.lib.fakeHash; # Calcul automatique au premier build
    };

    cargoHash = pkgs.lib.fakeHash; # Calcul automatique au premier build
    buildAndCheckSubdir = "spider_cli";

    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ];
  };

  # 5.3 Framework Agent Graph (PydanticAI)
  pydantic-ai = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pydantic_ai_slim";
    version = "0.0.18";
    format = "pyproject";
    src = pkgs.python3Packages.fetchPypi {
      pname = "pydantic_ai_slim";
      inherit version;
      hash = "sha256-DvbHn+GvS9le888ZvE9WbDDzwhtljjaJqPIPxzJCEtA=";
    };
    doCheck = false;
    dontCheckRuntimeDeps = true; # Désactive la vérification stricte des dépendances runtime optionnelles

    nativeBuildInputs = [ pkgs.python3Packages.hatchling ];
    propagatedBuildInputs = with pkgs.python3Packages; [
      pydantic
      httpx
      griffe
      eval-type-backport
    ];
  };

  # 6.2 Conversion Markdown LLM (Crawl4AI)
  crawl4ai = pkgs.python3Packages.buildPythonPackage rec {
    pname = "crawl4ai";
    version = "0.4.247";
    format = "setuptools";
    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-pGTb9hsM1RK7OHBpDmgWjAPc2ZP4YzY7isDKNhRWUIA=";
    };
    doCheck = false;
    
    # Correction du build sandbox Nix
    preBuild = ''
      export HOME=$(mktemp -d)
    '';

    propagatedBuildInputs = with pkgs.python3Packages; [
      pydantic
      httpx
      beautifulsoup4
    ];
  };
  #-------------------------------------------------------------------------------------------------
in

{
  nix.extraOptions = ''
    tarball-ttl = 0
  '';
  home = {
    username = local.sysName; # Informations sur l'utilisateur
    homeDirectory = "/home/${local.sysName}";
    sessionVariables = {
      # ----------------------------------------------------------------------
      # MAILLAGE GLOBAL : ROUTAGE, MÉMOIRE ET TÉLÉMÉTRIE
      # ----------------------------------------------------------------------
      # Routage Universel ➔ Façade OmniRoute (N3.1)
      OPENAI_API_BASE = "http://127.0.0.1:3000/v1";
      OPENAI_API_KEY = "sk-litellm-local-root-key";
      
      # Bypass sécurisé pour Guardrails AI (N4.2) si appelé en direct
      GUARDRAILS_API_BASE = "http://127.0.0.1:8005/v1";
      
      # Mémoire Long Terme Globale (N2.4)
      MEM0_HOST = "http://127.0.0.1:8081";
      MEM0_API_URL = "http://127.0.0.1:8081";

      # Observabilité LLMOps Névralgique (N5.4 Langfuse)
      LANGFUSE_HOST = "http://127.0.0.1:3001";
      LANGFUSE_PUBLIC_KEY = "pk-lf-local-key";
      LANGFUSE_SECRET_KEY = "sk-lf-local-key";

      # Endpoints d'Ingestion & Moteurs de Recherche (N2.1, N6.3)
      SEARXNG_URL = "http://127.0.0.1:8888";
      QDRANT_URL = "http://127.0.0.1:6333";

      # ----------------------------------------------------------------------
      # NIVEAU 4.3 : HARNAIS RUFLO (Connecté au maillage)
      # ----------------------------------------------------------------------
      RUFLO_LLM_ENDPOINT = "http://127.0.0.1:3000/v1"; # Pointe sur N3.1
      RUFLO_TELEMETRY_HOST = "http://127.0.0.1:3001";  # Pointe sur N5.4
      RUFLO_WORKTREE_ROOT = "/var/lib/ruflo/worktrees";
      RUFLO_DEFAULT_MODEL = "qwen-coder-fast";
    };
    packages = with pkgs; [
      # Paquets installés uniquement pour la session utilisateur
      #-----------------------------------------------APPs------------------------------------------------
      vlc
      vscode
      spotify
      unzip
      keepassxc
      obs-studio
      fastfetch
      htop
      nvtopPackages.amd
      pavucontrol
      sublime3
      qalculate-qt
      evince
      #----------------------------------------------Browser----------------------------------------------
      pkgs-unstable.tor-browser # dernière version possible "pkgs-unstable"
      pkgs-unstable.mullvad-browser # dernière version sur la stable "pkgs-stable-latest.mullvad-browser"
      pkgs-unstable.brave
      google-chrome
      #-----------------------------------------------Games-----------------------------------------------
      vesktop
      easyeffects
      lutris-free
      heroic
      protonup-qt
      lact
      gamescope
      goverlay
      mangohud
      #---------------------------------------------------------------------------------------------------
      #-------------------------------------------------IA------------------------------------------------
      opencode
      docker-compose
      llama-cpp-rocm
      mistral-rs
      clinfo
      rocmPackages.rocminfo
      # 4.1, 4.2 & 4.3
      nodejs
      cargo
      rustc
      uv # Executera instantanément Guardrails AI, MCP et RuFlo via virtualenv légers

      (pkgs.symlinkJoin {
        name = "appflowy-wrapped";
        paths = [ pkgs.appflowy ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/appflowy \
            --set AI_OPENAI_API_KEY "sk-litellm-local-root-key" \
            --set AI_OPENAI_HOST "http://127.0.0.1:3000/v1" \
            --set OLLAMA_HOST "http://127.0.0.1:3000" 
        '';
      })

      #-------------------------------------------
      (python3.withPackages (
        ps: with ps; [
          lancedb
          pyarrow
          # 4.1 Validation & Sorties Structurées
          pydantic
          pydantic-core
          # 5.3 Frameworks Agents Python
          langgraph
          # 5.1 Protocole MCP Python
          mcp
          # issue du bloc let-in
          spider-cli
          pydantic-ai
          #crawl4ai
          crawl4ai
        ]
      ))
      #-------------------------------------------
      # 6.5 Agent de Codage Terminal (déjà ajouté précédemment)
      opencode
      #--------------------------------------------------------------------------------------------------

      # Discord PTB + Vencord
      (discord-ptb.override {
        withVencord = true;
      })

      # Discord + Vencord
      (discord.override {
        withVencord = true;
      })
    ];
  };

  # Configuration directe des logiciels
  programs.git = {
    enable = true;
    settings = {
      user.name = local.gitName;
      user.email = local.gitEmail;
    };
  };

  programs.firefox = {
    enable = true;
    configPath = ".mozilla/firefox";
    profiles.${local.sysName} = {
      isDefault = true;
      settings = {
        "general.autoScroll" = true; # Active le défilement automatique pour une meilleure fluidité de navigation
        "privacy.resistFingerprinting" = false; # Protection contre le fingerprinting (+++FingerprintingResist, mais lourd sur l'ergo)
        "privacy.fingerprintingProtection" = false; # Protection contre le fingerprinting (+FingerprintingResist, alt moderne +leger)
        "dom.security.https_only_mode" = true; # Mode HTTPS (+confidentialité & sécurité)
        "privacy.donottrackheader.enabled" = false; # Désactive l'envoi de l'en-tête Do Not Track (+FingerprintingResist)
        "privacy.trackingprotection.enabled" = true; # Protection contre le tracking (+confidentialité)
        "datareporting.healthreport.uploadEnabled" = false; # Désactive l'envoi de rapports (+confidentialité)
        "app.normandy.enabled" = false; # Empêche Mozilla d'exécuter à distance des expérimentations ou des modifications (+confidentialité)
        "geo.enabled" = false; # Désactive la géolocalisation (+confidentialité)
        "media.peerconnection.ice.no_host" = true; # Désactive la découverte d'adresses IP locales via WebRTC (+confidentialité)
        "network.predictor.enabled" = false; # Désactive la prédiction de navigation (+confidentialité)
        "network.dns.disablePrefetch" = true; # Désactive la prélecture DNS (+confidentialité)
        "app.shield.optoutstudies.enabled" = false; # Empêche Mozilla de participer à des études de télémétrie (+confidentialité)
        "network.prefetch-next" = false; # Désactive la prélecture des liens (+confidentialité)
        "device.sensors.enabled" = false; # Désactive l'accès aux capteurs de l'appareil (+confidentialité)
        "dom.gamepad.enabled" = false; # Empêche la détection et l'énumération de manettes connectées. (+confidentialité)
        "browser.cache.disk.enable" = false; # Bascule du cache disque vers la RAM (1 Go max)
        "browser.cache.memory.enable" = true;
        "browser.cache.memory.capacity" = 1048576;
        "dom.battery.enabled" = false; # Désactive l'API Battery (+confidentialité)
        "media.navigator.enabled" = false; # Désactive l'accès à la caméra et au micro (+confidentialité)
        "dom.maxHardwareConcurrency" = 4; # Limite le nombre de threads pour réduire l'empreinte digitale (+FingerprintingResist)
        "webgl.enable-debug-renderer-info" = false; # Masque le modèle exact de la carte graphique dans WebGL
        "webgl.disabled" = false; # Désactive WebGL pour éviter les fuites d'informations sur le GPU (désactive map génie)
        "gfx.webrender.all" = true; # Accélération matérielle et rendu GPU sous Wayland
        "media.hardware-video-decoding.enabled" = true;
        "browser.startup.page" = 3; # Reouvrir automatiquement la derniere session (onglets ouverts)
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      }; # Desactivation taille minimale des onglets pour plus de fluidité et d'espace sur la barre d'onglets
      userChrome = ''
        #tabbrowser-tabs .tabbrowser-tab { 
          min-width: 0px !important;
        }
      '';
    };
  };

  # 5.1 Protocole MCP - Connexions directes aux services de la stack
  home.file.".config/opencode/mcp_servers.json".text = builtins.toJSON {
    mcpServers = {
      searxng = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mcp-server-searxng" "--searxng-url" "http://127.0.0.1:8888" ];
      };
      qdrant = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mcp-server-qdrant" "--qdrant-url" "http://127.0.0.1:6333" ];
      };
      spider = {
        command = "${pkgs.nodejs}/bin/npx";
        args = [ "-y" "@spider-rs/spider-mcp" ];
      };
      mem0 = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mem0-mcp" "--mem0-url" "http://127.0.0.1:8081" ];
      };
    };
  };

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}
