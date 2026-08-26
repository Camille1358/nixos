{ config, pkgs, ... }:
let
  local = import ./local.nix;
in
{
  # Informations sur l'utilisateur
  home.username = local.sysName; 
  home.homeDirectory = "/home/${local.sysName}";

  # Paquets installés uniquement pour ta session utilisateur
  home.packages = with pkgs; [
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

  (discord.override {
    withVencord = true;
  })

  # Discord PTB + Vencord
  (discord-ptb.override {
    withVencord = true;
  })
];

  # Configuration directe de tes logiciels personnels
  programs.git = {
    enable = true;
    userName = local.gitName;
    userEmail = local.gitEmail;
  };

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}