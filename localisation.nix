{ config, pkgs, ... }:

{
  # Configure console keymap
  console.keyMap = "fr";

    # Set your time zone.
  time.timeZone = "Europe/Paris";

  # Select internationalisation properties.
  i18n.defaultLocale = "fr_FR.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };
  
  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "fr";
    variant = "";
  };

  # Gestion des polices pour une meilleure compatibilité et lisibilité (+confidentialité)
  fonts = {
    enableDefaultPackages = false; # Désactive les paquets de polices par défaut inutiles
    packages = with pkgs; [
      liberation_ttf # Remplaçant standard des polices Arial/Times
      noto-fonts     # Standard mondial pour éviter le manque de glyphes
    ];
    fontconfig.defaultFonts = {
      sansSerif = [ "Liberation Sans" ];
      serif     = [ "Liberation Serif" ];
      monospace = [ "Liberation Mono" ];
    };
  };
}