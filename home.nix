{ config, pkgs, ... }:
let
  local = import ./local.nix;
  pkgs = import <nixpkgs> {};
  pkgs-stable-latest = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz") {};
  pkgs-unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {};
in
{
  nix.extraOptions = ''
    tarball-ttl = 0
  '';
  home = {
    username = local.sysName; # Informations sur l'utilisateur
    homeDirectory = "/home/${local.sysName}";
    packages = with pkgs; [ # Paquets installés uniquement pour ta session utilisateur
      vlc
      vscode
      easyeffects
      spotify
      unzip
      lutris-free
      heroic
      protonup-qt
      keepassxc
      obs-studio
      google-chrome
      mangohud
      goverlay
      pkgs-unstable.tor-browser #dernière version possible "pkgs-unstable"
      pkgs-unstable.mullvad-browser #dernière version sur la stable "pkgs-stable-latest.mullvad-browser"
      vesktop
      lact
      gamescope
      fastfetch
      htop
      nvtopPackages.amd
      pavucontrol
      sublime3
      qalculate-qt

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
        "privacy.fingerprintingProtection" = true; # Protection contre le fingerprinting (+FingerprintingResist, alt moderne +leger)
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

  systemd.services.auto-update-on-boot = {
  description = "Mise a jour des paquets au demarrage";
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
  };
  script = ''
    ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --refresh
  '';
  };

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}