{ config, pkgs, ... }:

{
  programs.bash = {
    shellAliases = {
      nrs = "sudo nixos-rebuild switch";
      nrsu = "sudo nix-channel --update && sudo nixos-rebuild switch";
    };
  };
}