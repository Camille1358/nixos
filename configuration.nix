# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

# pkgs-unstable est maintenant fourni par flake.nix (version verrouillée dans flake.lock)
{ config, pkgs, pkgs-unstable, ... }:

let
  local = import ./local.nix;
in

{
  # Les autres fichiers (bureau, jeux, IA...) ne sont plus listés ici : chacun est déclaré
  # dans le dossier modules/, chargé automatiquement. Voir modules/hote.nix.
  imports = [ ./hardware-configuration.nix ];

  nixpkgs.config.allowUnfree = true; # Allow unfree packages

  home-manager = { # Home-manager configuration
    useGlobalPkgs = true; # Utilise les paquets du système pour éviter les doublons
    useUserPackages = true; # Installe les paquets directement dans le profil utilisateur
    backupFileExtension = "avant-hm"; # Si un fichier existe déjà (ex. réglages GTK écrits par KDE), il est renommé au lieu de bloquer
    # (la configuration de ton utilisateur est assemblée dans modules/hote.nix)
  };

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib # pour claude
    zlib
    glibc 
  ];

  # Bootloader.
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernel.sysctl = {
      "vm.swappiness" = 10; # Réduit l'utilisation du swap pour améliorer les performances
      "net.core.default_qdisc" = "fq"; # Utilise l'algorithme de file d'attente FQ pour améliorer la gestion du trafic réseau
      "net.ipv4.tcp_congestion_control" = "bbr"; # Active l'algorithme de contrôle de congestion BBR pour améliorer les performances réseau
      "vm.dirty_bytes" = 268435456; # 256 Mo, Fluidité système et suppression des micro-gels I/O (E/S Disque)
      "vm.dirty_background_bytes" = 67108864; # 64 Mo
    };
    # (les réglages du noyau propres aux jeux sont dans games_drivers.nix)
    kernelPackages = pkgs.linuxPackages_latest; # Use latest kernel.
    supportedFilesystems = [ "ntfs" "exfat" ]; 
  };

  # auto-update
  #system.autoUpgrade = {
  #  enable = true;
  #  dates = "weekly";
  #};

  nix = {
    gc = {
      automatic = true; # Automatic garbage collection
      dates = "weekly";
      options = "--delete-older-than 100d"; # Delete packages older than 100 days
    };
    settings.auto-optimise-store = true; # Auto-optimise store
  };

  networking = {
    hostName = "host"; # Define your hostname. ("nixos" used by default), used host for confidentiality and security
    networkmanager = {
      enable = true; # Enable networking
      wifi.scanRandMacAddress = true; # MAC aléatoire pour le scan Wi-Fi
      ethernet.macAddress = "random";
      wifi.macAddress = "random";
    };
    # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
    # networking.proxy.default = "http://user:password@proxy:port/"; # Configure network proxy if necessary
    # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";
    #firewall.allowedTCPPorts = [ 5432 ];
  };

  services = {
    printing.enable = true; # Enable CUPS to print documents.
    pulseaudio.enable = false; # Enable sound with pipewire.
    fstrim.enable = true; # Enable periodic TRIM for SSDs.
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      # jack.enable = true; # If you want to use JACK applications, uncomment this
      # media-session.enable = true; # use the example session manager (no others are packaged yet so this is enabled by default, no need to redefine it in your config for now)
    };
  };

  security.rtkit.enable = true;

  users.users."${local.sysName}" = { # Define a user account. Don't forget to set a password with ‘passwd’.
    isNormalUser = true;
    description = local.sysName;
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
    ];
  };

  # Ferme immédiatement le processus fautif en cas d'épuisement de la RAM pour éviter le gel complet du système.
  systemd.oomd.enable = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    warn-dirty = false; # pas d'avertissement "Git tree is dirty" si une commande passe quand même par git
  };
  programs.git.enable = true; # Requis par les flakes (root doit pouvoir appeler git)

  # Gestion de la mémoire et réactivité système
  zramSwap.enable = true;

  #----------------------------------------Control-Flux-Internet-----------------------------------------
  #control total de mon flux internet
  services.opensnitch = {
    enable = true;

    rules = {
      # Autoriser tout le trafic local (Loopback + LAN)
      allow-all-local-networks = {
        name = "allow-all-local-networks";
        enabled = true;
        action = "allow";
        duration = "always";
        operator = {
          type = "list";
          operand = "dest.network";
          data = "127.0.0.0/8, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12";
        };
      };
    };
  };

  # Éclairage RGB (OpenRGB, clavier ROCCAT compris) : voir rgb/default.nix

  

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
