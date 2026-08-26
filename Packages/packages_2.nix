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
}
