{ config, pkgs, ... }:

{
  # Configure console keymap
  console.keyMap = "fr";

    # Set your time zone.
  time.timeZone = "Europe/Paris";

  # Select internationalisation properties.
  i18n.defaultLocale = "fr_FR.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8"; #${local.sysName}
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };
  
  # Clavier AZERTY français "standard" (le même agencement que Windows pour les touches courantes).
  # Ce réglage est repris par Hyprland (voir desktop-home.nix) : on le définit ici, une seule fois.
  services.xserver.xkb = {
    layout = "fr";
    variant = "";
    model = "pc105";
    # Verr. Maj comme sur Windows, mais sans "bloquer Maj" :
    #   - les lettres passent en majuscules ;
    #   - la rangée du haut donne les chiffres (1 2 3... au lieu de & é ") ;
    #   - les autres touches ne changent pas : les flèches ne sélectionnent plus le texte.
    # Pour un Verr. Maj qui ne touche QUE les lettres (rangée du haut inchangée), mets "".
    # (L'ancien réglage KDE "caps:shiftlock" maintenait Maj enfoncée sur toutes les touches,
    #  flèches comprises : c'est ce qui sélectionnait le texte.)
    options = "caps:digits_row";
  };

  # Les touches mortes (^ ¨) se règlent dans le fichier .XCompose, installé dans ton
  # dossier personnel par desktop-home.nix.
  #
  # Problème : VS Code, Discord, Brave et Chrome (applications "Electron / Chromium")
  # ignorent ce fichier et gèrent les accents à leur façon : ^ deux fois n'y donne qu'un ^.
  # Solution : un gestionnaire de saisie (fcitx5) qui s'intercale entre le clavier et TOUTES
  # les applications, et applique .XCompose partout.
  # Il est lancé par startup.nix. Pour revenir en arrière : enable = false, puis nrs.
  i18n.inputMethod = {
    enable = false; # désactivé : il cassait Verr. Maj (constaté le 14/10)
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true; # parle directement à Hyprland (pas de variables GTK/Qt à poser)
      ignoreUserConfig = true; # seuls les réglages ci-dessous comptent
      settings = {
        # Une seule "méthode de saisie" : le clavier français, tel que réglé plus haut.
        inputMethod = {
          "Groups/0" = {
            Name = "Default";
            "Default Layout" = "fr";
            DefaultIM = "keyboard-fr";
          };
          "Groups/0/Items/0".Name = "keyboard-fr";
          GroupOrder."0" = "Default";
        };
        # fcitx5 réserve d'office des raccourcis (Ctrl+Espace, Super+Espace...) pour
        # changer de langue : on les vide tous, sinon ils voleraient ton lanceur.
        globalOptions = {
          "Hotkey/TriggerKeys" = { };
          "Hotkey/AltTriggerKeys" = { };
          "Hotkey/EnumerateForwardKeys" = { };
          "Hotkey/EnumerateBackwardKeys" = { };
          "Hotkey/EnumerateGroupForwardKeys" = { };
          "Hotkey/EnumerateGroupBackwardKeys" = { };
          "Hotkey/ActivateKeys" = { };
          "Hotkey/DeactivateKeys" = { };
          Hotkey.EnumerateWithTriggerKeys = "False";
          Behavior.ShowInputMethodInformation = "False"; # pas de bulle "Clavier - Français"
        };
      };
    };
  };
}