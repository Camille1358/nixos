{ config, pkgs, ... }:

{
  programs = {
    steam = {
      enable = true;
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      extraCompatPackages = with pkgs; [
        proton-ge-bin # Ajoute automatiquement Proton-GE dans Steam
      ];
    };
    gamescope.enable = true; # gameScope for game stability
    gamemode.enable = true; # gameMode for game stability & performance
  };
}