# TOUT ce qui se lance tout seul à l'ouverture de session est déclaré ici.
# Pour qu'un programme ne démarre plus : supprimer (ou commenter) son bloc, puis nrs.
#
# Ce qui démarre aussi, mais qui n'est pas une application — c'est le bureau lui-même,
# sans quoi l'écran serait vide (déclaré dans desktop-home.nix) :
#   barre du haut, fond d'écran, notifications, veille automatique, demandes de mot de passe.
# Les services IA (moteur, passerelle, Open WebUI...) démarrent avec la machine ; ils se
# coupent un par un dans IA/parametres.nix (bloc "actif").
{ config, lib, pkgs, ... }:

let
  local = import ./local.nix;
  ia = import ./IA/parametres.nix;
in
{
  # Journal des notifications : note chaque notification reçue (application, titre, texte,
  # date et heure) pour l'historique de la cloche de la barre (panneaux/). N'affiche rien
  # lui-même : il écoute seulement ce que les applications envoient.
  # Les notifications passagères (jauge du volume, pastille de dictée) ne sont pas gardées.
  systemd.user.services.journal-notifications = {
    description = "Journal des notifications (historique de la cloche)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    path = [ pkgs.dbus pkgs.gawk pkgs.procps pkgs.coreutils ];
    script = ''
      dossier="''${XDG_STATE_HOME:-$HOME/.local/state}/notifications"
      mkdir -p "$dossier"
      dbus-monitor --session "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" |
      awk -v journal="$dossier/journal.jsonl" '
        # Texte sûr dans une ligne JSON
        function esc(s) {
          gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s)
          gsub(/\r/, "", s); gsub(/\n/, "\\n", s); return s
        }
        # Argument texte de dbus-monitor :  string "...."  (peut tenir sur plusieurs lignes)
        function texte(s) { sub(/^   string "/, "", s); sub(/"$/, "", s); return s }
        # Début d une notification (avec son heure exacte)
        /^method call time=.*member=Notify$/ {
          split($3, morceaux, "="); heure = int(morceaux[2]); n = 0; tampon = ""; enCours = 1; next
        }
        # Chaque argument commence par son type, en début de ligne (3 espaces)
        enCours && /^   (string|uint32|int32|array|boolean|int64|double|byte) / {
          if (n > 0) argument[n] = tampon
          n++; tampon = $0
          if (n == 8) {  # 1 appli, 2 remplace, 3 icône, 4 titre, 5 texte, 6 actions, 7 indications
            enCours = 0
            if (argument[7] ~ /x-canonical-private-synchronous|"transient"/) next
            appli = texte(argument[1]); if (appli == "") appli = "Système"
            printf "{\"t\":%d,\"app\":\"%s\",\"titre\":\"%s\",\"texte\":\"%s\"}\n", heure, \
              esc(appli), esc(texte(argument[4])), esc(texte(argument[5])) >> journal
            close(journal)
            system("pkill -RTMIN+10 waybar")  # la cloche de la barre se met à jour
          }
          next
        }
        enCours { tampon = tampon "\n" $0 }
      '
    '';
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Bouton "réduire" des fenêtres : écoute Hyprland et range la fenêtre réduite hors de vue.
  # Elle réapparaît dans la barre du haut (icône à gauche des icônes de la zone de
  # notification) ; un clic dessus ouvre la liste pour la ramener.
  # (Fonctionne avec la modification locale de Hyprland déclarée dans desktop.nix.)
  systemd.user.services.reduire = {
    description = "Rangement des fenêtres réduites";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    path = [ config.programs.hyprland.package pkgs.socat pkgs.procps pkgs.coreutils ];
    script = ''
      canal="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
      socat -U - "UNIX-CONNECT:$canal" | while IFS= read -r evenement; do
        case "$evenement" in
          "minimized>>"*",1")
            # Format : minimized>>ADRESSE,1  (adresse de la fenêtre, sans le 0x)
            adresse=''${evenement#minimized>>}
            adresse=''${adresse%,1}
            hyprctl dispatch "hl.dsp.window.move({ window = \"address:0x$adresse\", workspace = \"special:reduites\", follow = false })"
            pkill -RTMIN+9 waybar
            ;;
          movewindowv2*|closewindow*|openwindow*)
            pkill -RTMIN+9 waybar # mettre à jour le compteur de la barre
            ;;
        esac
      done
    '';
    serviceConfig = {
      Restart = "always"; # se reconnecte si Hyprland redémarre
      RestartSec = 2;
    };
  };

  # Gestionnaire de saisie (accents "comme sur Windows" partout) : voir localisation.nix
  systemd.user.services.fcitx5 = lib.mkIf config.i18n.inputMethod.enable {
    description = "Gestionnaire de saisie fcitx5 (accents)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${config.i18n.inputMethod.package}/bin/fcitx5";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };

  # Handy : dictée vocale (maintenir Ctrl droit). Icône dans la barre.
  systemd.user.services.handy = {
    description = "Handy (dictée vocale) en arrière-plan";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "pipewire.service" ];
    serviceConfig = {
      # Le programme vient de applis.nix (installé dans ton profil utilisateur).
      ExecStart = "/etc/profiles/per-user/${local.sysName}/bin/handy --start-hidden";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.user.services.easyeffects = {
    description = "Service EasyEffects en arrière-plan";
    wantedBy = [ "graphical-session.target" ];
    wants = [ "pipewire.service" ];
    after = [ "pipewire.service" "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
      Restart = "on-failure";
    };
  };

  systemd.user.services.opensnitch-ui = {
    description = "Interface graphique OpenSnitch au démarrage de la session";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.opensnitch-ui}/bin/opensnitch-ui";
      Restart = "on-failure";
    };
  };

  # Mémoire de l'IA locale : les nouveaux messages des conversations avec Claude Code sont
  # ajoutés à la mémoire partagée (Qdrant), toutes les 30 minutes. Ne relit que le nouveau ;
  # ne fait rien (et ne lance rien) s'il n'y a rien de nouveau. Réglages : IA/parametres.nix,
  # bloc "memoire" ; outil : memoire-conversations (IA/home.nix).
  systemd.user.services.memoire-conversations = lib.mkIf (ia.actif.qdrant && ia.memoire.conversations) {
    description = "Conversations avec Claude Code vers la mémoire de l'IA locale (Qdrant)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/etc/profiles/per-user/${local.sysName}/bin/memoire-conversations";
      Nice = 15;
      IOSchedulingClass = "idle";
    };
  };
  systemd.user.timers.memoire-conversations = lib.mkIf (ia.actif.qdrant && ia.memoire.conversations) {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = ia.memoire.conversationsToutesLes;
    };
  };

  systemd.user.services.auto-update = {
    description = "Mise à jour automatique des paquets critiques au démarrage";
    wantedBy = [ "default.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    script = ''
      # Liste ici les paquets du store nixos-unstable à maintenir à jour
      PACKAGES=(
        "nixpkgs#tor-browser"
        "nixpkgs#mullvad-browser"
      )

      for pkg in "''${PACKAGES[@]}"; do
        ${pkgs.nix}/bin/nix profile install --tarball-ttl 0 "$pkg"
      done
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
  };
}