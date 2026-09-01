{ config, pkgs, ... }:

{
  system.autoUpgrade.flags = [
    "--update-input" "nixpkgs"
    "--commit-lock-file"
  ];
}