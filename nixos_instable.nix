{ config, lib, pkgs, modulesPath, ... }:

let
  pkgs-unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  # Ton reste de configuration...

  hardware.graphics.package = pkgs-unstable.mesa.drivers;
  hardware.graphics.package32 = pkgs-unstable.pkgsi686Linux.mesa.drivers;
}