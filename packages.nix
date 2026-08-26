{ config, pkgs, ... }:

{
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  #gamescope for game stability
  programs.gamescope.enable = true;

  #gamemode for game stability & performance
  programs.gamemode.enable = true;
}