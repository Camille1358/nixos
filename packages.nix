{ config, pkgs, ... }:

{
  programs = {
    steam = {
      enable = true;
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
    };
    gamescope.enable = true; #gamescope for game stability
    gamemode.enable = true; #gamemode for game stability & performance
  };
}