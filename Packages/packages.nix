{ config, pkgs, ... }:
#logiciel
{
  environment.systemPackages = with pkgs; [
    git
    vlc
    vscode
    fastfetch
    easyeffects
    vesktop
    spotify
    unzip
    lutris-free
    protonup-qt
    keepassxc
    firefox
    obs-studio
    google-chrome
  ];
}
