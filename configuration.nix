# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  local = import ./local.nix;
in

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./alias.nix
      ./localisation.nix
      ./nixos_instable.nix
      ./gaming_driver.nix
      ./packages.nix
      <home-manager/nixos>
    ];

  home-manager = { #home-manager configuration
    useGlobalPkgs = true; # Utilise les paquets du système pour éviter les doublons
    useUserPackages = true; # Installe les paquets directement dans le profil utilisateur
    users.${local.sysName} = import ./home.nix;
  };

  # Bootloader.
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages_latest; # Use latest kernel.
  };

  #auto-update
  system.autoUpgrade = {
    enable = true;
    dates = "weekly";
  };

  nix = {
    gc = {
      automatic = true; #automatic garbage collection
      dates = "weekly";
      options = "--delete-older-than 100d"; #delete packages older than 100 days
    };
    settings.auto-optimise-store = true; #auto-optimise store
  };

  networking = {
    hostName = "nixos"; # Define your hostname.
    networkmanager.enable = true; # Enable networking
    # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
    # networking.proxy.default = "http://user:password@proxy:port/"; # Configure network proxy if necessary
    # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";
  };

  services = {
    xserver.enable = true; # Enable the X11 windowing system. You can disable this if you're only using the Wayland session.
    desktopManager.plasma6.enable = true;
    printing.enable = true; # Enable CUPS to print documents.
    pulseaudio.enable = false; # Enable sound with pipewire.
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      #jack.enable = true; # If you want to use JACK applications, uncomment this
      #media-session.enable = true; # use the example session manager (no others are packaged yet so this is enabled by default, no need to redefine it in your config for now)
    };
    displayManager = {
      sddm.enable = true; # Enable the KDE Plasma Desktop Environment.
      autoLogin = { # Connexion automatique sans mot de passe
        enable = true;
        user = local.sysName;
      };
    };
  };

  security.rtkit.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."${local.sysName}" = {
    isNormalUser = true;
    description = local.sysName;
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #  wget

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?

}
