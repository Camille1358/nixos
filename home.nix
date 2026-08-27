{ config, pkgs, ... }:
let
  local = import ./local.nix;
in
{
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
      vesktop
      lact
      gamescope
      fastfetch
      htop
      nvtopPackages.amd
      pavucontrol

    # Discord + Vencord
      (discord.override {
        withVencord = true;
      })

      # Discord PTB + Vencord
      (discord-ptb.override {
        withVencord = true;
      })
    ];
  };

  # Configuration directe de tes logiciels personnels
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
        "privacy.resistFingerprinting" = true; # Active la protection contre le fingerprinting pour une meilleure confidentialité
        "privacy.donottrackheader.enabled" = false; # Désactive l'envoi de l'en-tête Do Not Track pour une meilleur protection contre le fingerprinting
        "browser.cache.disk.enable" = false; # Bascule du cache disque vers la RAM (1 Go max)
        "browser.cache.memory.enable" = true;
        "browser.cache.memory.capacity" = 1048576;
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