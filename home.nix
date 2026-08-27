{ config, pkgs, ... }:
let
  local = import ./local.nix;
in
{
  home ={
    username = local.sysName; # Informations sur l'utilisateur
    homeDirectory = "/home/${local.sysName}";
    packages = with pkgs; [ # Paquets installés uniquement pour ta session utilisateur
      vlc
      vscode
      fastfetch
      easyeffects
      spotify
      unzip
      lutris-free
      protonup-qt
      keepassxc
      firefox
      obs-studio
      google-chrome
      mangohud
      vesktop

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

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}