{ config, lib, pkgs, modulesPath, ... }:

let
  pkgs-unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware = {
    cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    steam-hardware.enable = true; # Active le support matériel pour Steam et les jeux sous Proton
    xpadneo.enable = true; # Ce pilote améliore la stabilité et la gestion de la batterie des manettes Xbox en Bluetooth.
    graphics = { # hardware.opengl has beed changed to hardware.graphics
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
      rocmPackages.clr.icd
      rocmPackages.rocblas
      rocmPackages.hipblas
      rocmPackages.rocm-smi
      ];
      package = pkgs-unstable.mesa;
      package32 = pkgs-unstable.pkgsi686Linux.mesa;
    };
    amdgpu.opencl.enable = true; # Active le support OpenCL pour les GPU AMD
  };

  services.xserver.videoDrivers = ["amdgpu"];

  environment.variables = {
    AMD_VULKAN_ICD = "RADV";
    MESA_GL_THREAD = "true";
  };

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
    gamemode.enable = true; # gameMode for game stability & performance
    gamescope.enable = true; # gameScope for game stability
  };
}