{ config, pkgs, ... }:

let
  local = import ./local.nix;
  pkgs-stable-latest = import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz") {
    config.allowUnfree = true;
  };
  pkgs-unstable = import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {
    config.allowUnfree = true;
  };

#-----------------------------------------------IA------------------------------------------------
  # 6.1 Dérivation personnalisée Nix pour Spider CLI depuis Crates.io
  spider-cli = pkgs.rustPlatform.buildRustPackage rec {
    pname = "spider_cli";
    version = "2.2.0";

    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Temporaire pour obtenir le vrai hash
    };

    cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ];
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
    packages = with pkgs; [ # Paquets installés uniquement pour la session utilisateur
    #-----------------------------------------------APPs------------------------------------------------
      vlc
      vscode
      spotify
      unzip
      keepassxc
      obs-studio
    #----------------------------------------------Browser----------------------------------------------
      pkgs-unstable.tor-browser #dernière version possible "pkgs-unstable"
      pkgs-unstable.mullvad-browser #dernière version sur la stable "pkgs-stable-latest.mullvad-browser"
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
      fastfetch
      htop
      nvtopPackages.amd
      pavucontrol
      sublime3
      qalculate-qt
      evince
    #------------------------------------------------IA------------------------------------------------
      appflowy
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

      #-------------------------------------------
      (python3.withPackages (ps: with ps; [
        lancedb
        pyarrow
        # 4.1 Validation & Sorties Structurées
        pydantic
        pydantic-core
        # 5.3 Frameworks Agents Python
        langgraph
        # 5.1 Protocole MCP Python
        mcp
      ]))
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

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}