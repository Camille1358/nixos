{ config, lib, pkgs, modulesPath, ... }:

let
  pkgs-unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  hardware.graphics.package = pkgs-unstable.mesa;
  hardware.graphics.package32 = pkgs-unstable.pkgsi686Linux.mesa;
}