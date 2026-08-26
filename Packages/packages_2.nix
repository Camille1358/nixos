{ config, pkgs, ... }:
#logiciel
{
  environment.systemPackages = with pkgs; [
  (discord.override {
    withVencord = true;
  })

  # Discord PTB + Vencord
  (discord-ptb.override {
    withVencord = true;
  })
  ];
  
  programs.steam = {
  enable = true;
  gamescopeSession.enable = true;
  remotePlay.openFirewall = true;
  dedicatedServer.openFirewall = true;
  };
  programs.gamemode.enable = true;
}
