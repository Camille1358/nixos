# Bureau Wayland uniquement (Hyprland) : partie système.
# La partie utilisateur (barre, thème, raccourcis, config de Hyprland) est dans desktop-home.nix.
{ config, pkgs, ... }:

let
  local = import ./local.nix;
in
{
  # --- Compositeur ----------------------------------------------------------
  # Enregistre la session Wayland + polkit, accélération GPU, portail.
  programs.hyprland.enable = true;
  # Petite modification locale de Hyprland (fichier hyprland-reduire.patch) : quand tu cliques
  # sur le bouton "réduire" d'une fenêtre, Hyprland le signale enfin (version 0.55 : il
  # l'ignorait). Le script "reduire" (desktop-home.nix) range alors la fenêtre en haut à droite.
  # Contrepartie : Hyprland est compilé sur ta machine (quelques minutes à chaque mise à jour).
  programs.hyprland.package = pkgs.hyprland.overrideAttrs (ancien: {
    patches = (ancien.patches or [ ]) ++ [
      ./hyprland-reduire.patch # bouton "réduire"
      ./hyprland-commandes.patch # clic sur les bureaux virtuels de la barre
      # Clic molette sur du texte (curseur en I) = rien : aucune application ne colle, même
      # celles qui n'ont pas de réglage pour ça (VS Code, Discord, Steam). Voir le fichier.
      ./hyprland-clic-molette.patch
    ];
  });

  # --- Connexion (sans X11) -------------------------------------------------
  # greetd + tuigreet : écran de connexion texte, 100 % Wayland/TTY, aucun serveur X.
  # initial_session = connexion automatique au démarrage, SANS identifiant ni mot de passe
  # (remplace l'autologin SDDM) : tu arrives direct dans Hyprland.
  # default_session = l'écran de connexion (tuigreet). Il ne s'affiche que si tu te
  # déconnectes volontairement (Super+Maj+E ou "Déconnexion" dans le menu session).
  # ATTENTION : si la commande de initial_session n'existe pas, greetd retombe sur
  # l'écran de connexion à chaque démarrage. Sous Hyprland 0.53+, c'est "start-hyprland".
  services.greetd = {
    enable = true;
    settings = {
      initial_session = {
        command = "start-hyprland";
        user = local.sysName;
      };
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd start-hyprland";
        user = "greeter";
      };
    };
  };

  # --- Services utilisés par le bureau (Bluetooth, profils d'énergie, batterie) ---
  hardware.bluetooth.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  # (NetworkManager est déjà activé dans configuration.nix)

  # --- Portails : partage d'écran (OBS, Discord) et sélecteur de fichiers ---
  # Hyprland ajoute son portail ; on garde juste le portail GTK en plus.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Fait tourner Electron/Chromium (Discord, Vesktop, VS Code, Brave, Chrome) en Wayland natif
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Police avec icônes, utilisée par la barre, le lanceur et le terminal
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # Verrouillage d'écran (hyprlock a besoin de son service PAM) et réglages GTK (thème sombre)
  security.pam.services.hyprlock = { };
  programs.dconf.enable = true;

  # Gestionnaire de fichiers : Dolphin (installé dans home.nix). gvfs : corbeille, clés USB.
  services.gvfs.enable = true;

  # Index des thèmes d'icônes (icon-theme.cache), pour le système et ton profil. Sans eux,
  # chaque application GTK parcourt des milliers de dossiers d'icônes à son démarrage.
  # (Activé d'office seulement avec X11 ; ici tout est Wayland, d'où ce réglage.)
  gtk.iconCache.enable = true;
}
