# Bureau Wayland (Hyprland) : partie utilisateur (home-manager).
# osConfig = la config système (permet de reprendre ta disposition de clavier).
#
# Ce fichier contient, dans l'ordre :
#   1. RÉGLAGES        ce que tu changes souvent (transparence, couleurs, délais de veille)
#   2. Scripts         volume, capture, menu session, calendrier
#   3. Waybar          la barre du haut (contenu puis apparence)
#   4. Hyprland        fenêtres, animations, raccourcis clavier
#   5. Le reste        lanceur, notifications, veille automatique, verrouillage, terminal, thème sombre
#
# RACCOURCIS (Super = touche Windows)
#   Super+Espace / Super+D   lanceur d'applications
#   Super+Entrée             terminal
#   Super+E                  fichiers
#   Super+Q                  fermer la fenêtre
#   Super+F                  plein écran (refaire Super+F pour en sortir)
#   Super+M                  agrandir la fenêtre en gardant la barre (refaire pour revenir)
#   Super+V                  fenêtre flottante / en mosaïque
#   Super+N                  réduire la fenêtre (la ranger hors de vue)
#   Super+Maj+N              afficher / cacher les fenêtres réduites
#   Super+X                  menu session (éteindre, veille, arrêt programmé...)
#   Super+C                  agenda
#   Super+L                  verrouiller
#   Super+B                  masquer / afficher la barre
#
#   Les fenêtres sont des COLONNES sur un ruban qui défile (comme Niri) :
#   Super+flèches            changer de fenêtre (gauche/droite = colonne voisine)
#   Super+Maj+gauche/droite  déplacer la colonne        (+haut/bas : la fenêtre dans sa colonne)
#   Super+Ctrl+gauche/droite élargir / rétrécir la colonne (+haut/bas : la hauteur)
#   Super+R                  largeur suivante : 1/3, 1/2, 2/3, tout l'écran
#   Super+, / Super+;        glisser la fenêtre dans la colonne de gauche / droite (ou l'en sortir)
#   Super+molette            faire défiler le ruban
#
#   Super+1..9               changer d'espace de travail (+Maj : y envoyer la fenêtre)
#   Super+clic gauche/droit  déplacer / redimensionner une fenêtre à la souris
#   Alt+Tab                  choisir une fenêtre parmi toutes (miniatures) : maintenir Alt,
#                            Tab / Maj+Tab ou flèches pour choisir, relâcher Alt ; Échap annule
#   Impr écran               capture d'une zone, puis aperçu : copier / enregistrer / enregistrer sous
#   Maj+Impr écran           capture de l'écran entier, même aperçu
{ config, pkgs, lib, osConfig, ... }:

let
  # ===========================================================================
  # 1. RÉGLAGES — tout ce que tu as envie de changer souvent est ici.
  # Après modification : nrsf
  # ===========================================================================

  # true  = barre transparente (les modules flottent sur le fond d'écran)
  # false = barre pleine, sombre
  barreTransparente = true;

  # Cloche des notifications de la barre : simple cloche, ou cloche qui sonne s'il y a
  # des notifications non lues. Survol = les dernières, groupées par application.
  notifsSurvol = 10; # nombre de notifications affichées au survol
  clocheAnimee = false; # true = en plus, la cloche s'agite tant qu'il y a du non lu

  # Petit son à l'arrivée d'une notification (thème de sons "Ocean" de KDE Plasma).
  # "" = jamais de son. Autres choix : "message-highlight", "dialog-information", "bell"...
  sonNotification = "message-new-instant";
  # Applications qui jouent déjà leur propre son : pas de second son par-dessus.
  # (nom de l'application tel qu'elle l'envoie ; il apparaît en gras dans l'historique)
  sansSonPour = [ "discord" ];

  # Vitesse de défilement de la molette, dans toutes les applications : 1.0 = normale,
  # 2.0 = deux fois plus de lignes par cran. (Firefox ajoute sa propre vitesse par-dessus.)
  defilement = 2.0;

  # Taille de l'interface de Steam (affiché aux vrais pixels de l'écran 4K, donc net) :
  # 1.5 = même taille que les autres applis, 2.0 = plus grand. Relancer Steam après nrs.
  steamTaille = 2.0;

  # Défilement automatique façon Windows, dans TOUTES les applications : un clic molette (sans
  # rester appuyé), puis la page défile toute seule vers la souris, sans fin ; un clic ou Échap
  # arrête. Vitesse : pages par seconde quand la souris est à 10 points du point de départ
  # (à 20 points : deux fois plus vite). Une "page" = la hauteur de la fenêtre.
  defilementVitesse = 1.0;
  # Applications à laisser à leur propre défilement automatique (nom de la fenêtre, en
  # minuscules : voir hyprctl clients). Vide : le même défilement partout.
  defilementAutoSauf = [ ];

  # Veille automatique quand tu ne touches à rien (en minutes).
  # L'écran s'éteint toujours. La mise en veille de l'ordinateur, elle, peut être
  # coupée depuis le menu session de la barre (bouton rouge) pour le laisser tourner.
  ecranEnVeilleApres = 10;
  ordiEnVeilleApres = 30;

  # Palette néon / cyberpunk (fond noir obligatoire). Format : RRGGBB, sans "#".
  c = {
    bg = "0a0a12"; # fond principal (quasi noir)
    surface = "12121f"; # fond des modules de la barre
    surface2 = "1c1c2e"; # survol / sélection
    text = "d7e0ff";
    muted = "5c6380"; # texte discret
    magenta = "ff2e97";
    cyan = "00f0ff";
    violet = "b47cff";
    yellow = "fcee0a";
    green = "39ff88";
    orange = "ff9e3d";
    red = "ff3860";
  };

  font = "JetBrainsMono Nerd Font";

  # Fond d'écran : dégradé sombre avec halos néon (généré à la compilation).
  # Pour une image à toi, remplace par un chemin entre guillemets, ex. "/home/host/Images/fond.png"
  wallpaper = pkgs.runCommand "fond.png" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    magick -size 3840x2160 xc:'#${c.bg}' \
      \( -size 3400x3400 radial-gradient:'#${c.magenta}66-#${c.magenta}00' \) -gravity southwest -geometry -1100-1500 -composite \
      \( -size 3400x3400 radial-gradient:'#${c.cyan}4d-#${c.cyan}00' \) -gravity northeast -geometry -1100-1500 -composite \
      \( -size 2600x2600 radial-gradient:'#${c.violet}33-#${c.violet}00' \) -gravity center -geometry +0+0 -composite \
      -attenuate 0.12 +noise Gaussian -depth 8 $out
  '';

  # ===========================================================================
  # 2. Scripts
  # ===========================================================================

  terminalBin = "${config.programs.kitty.package}/bin/kitty"; # terminal : Kitty
  rofiBin = "${config.programs.rofi.finalPackage}/bin/rofi";
  layout = osConfig.services.xserver.xkb.layout;

  # Icône Nerd Font à partir de son code (ex. ic "f011" = bouton d'alimentation).
  # Liste des codes : https://www.nerdfonts.com/cheat-sheet
  # (Les codes à 5 chiffres, comme f0200, sont écrits en deux morceaux : c'est ainsi que le
  #  format JSON note les caractères au-delà de FFFF.)
  ic = code:
    if builtins.stringLength code <= 4 then builtins.fromJSON ''"\u${code}"''
    else
      let
        n = lib.fromHexString code - 65536;
        haut = lib.toHexString (55296 + n / 1024);
        bas = lib.toHexString (56320 + lib.mod n 1024);
      in
      builtins.fromJSON ''"\u${haut}\u${bas}"'';

  # Panneaux déroulants de la barre : agenda, menu session, son (programme en Rust : dossier panneaux/).
  # Relancer la commande, cliquer en dehors ou appuyer sur Échap referme le panneau.
  hauteurBarre = 44;
  panneauxTheme = pkgs.writeText "panneaux-theme.json" (builtins.toJSON {
    couleurs = c;
    police = font;
    inherit hauteurBarre ordiEnVeilleApres notifsSurvol clocheAnimee defilementAutoSauf defilementVitesse;
  });
  # Programme en Rust (dossier panneaux/), avec GTK 4. Ses tests automatiques tournent à
  # chaque construction : s'ils échouent, nrs s'arrête au lieu d'installer un panneau cassé.
  panneaux = pkgs.rustPlatform.buildRustPackage {
    pname = "panneaux";
    version = "2.0.0";
    src = lib.fileset.toSource {
      root = ./panneaux;
      fileset = lib.fileset.unions [ ./panneaux/Cargo.toml ./panneaux/Cargo.lock ./panneaux/src ];
    };
    cargoLock.lockFile = ./panneaux/Cargo.lock;
    nativeBuildInputs = [ pkgs.pkg-config pkgs.wrapGAppsHook4 ];
    buildInputs = [ pkgs.gtk4 pkgs.gtk4-layer-shell ];
    preFixup = ''
      gappsWrapperArgs+=(
        --set PANNEAUX_THEME ${panneauxTheme}
        # Dessin par le processeur (cairo) plutôt que par la carte graphique : pour de petits
        # panneaux, 75 Mo de mémoire au lieu de 200, et deux fois moins de calcul à l'ouverture
        # (mesuré). Le flou et la transparence restent faits par Hyprland.
        --set-default GSK_RENDERER cairo
        --prefix PATH : ${lib.makeBinPath [
          pkgs.systemd pkgs.pulseaudio pkgs.libnotify pkgs.procps pkgs.pavucontrol pkgs.wl-clipboard
          pkgs.grim pkgs.coreutils # miniatures (Alt+Tab, partage) ; timeout : arrêter une capture bloquée
          pkgs.networkmanager pkgs.util-linux pkgs.bluez pkgs.networkmanagerapplet # réseau
          pkgs.mako # makoctl (notifications)
          pkgs.wireplumber pkgs.slurp config.programs.rofi.finalPackage # volume, capture, lanceur
          pkgs.tesseract # capture : texte de l'image (OCR)
          config.programs.hyprlock.package osConfig.programs.hyprland.package
        ]}
      )
    '';
  };
  panneau = nom: "${panneaux}/bin/panneaux ${nom}";

  # Partage d'écran : notre sélecteur (panneaux/src/partage.rs) remplace la fenêtre blanche du
  # portail de Hyprland. Le portail lance un programme sans argument, d'où ce petit lanceur.
  selecteurPartage = pkgs.writeShellScript "selecteur-partage" ''exec ${panneaux}/bin/panneaux partage "$@"'';

  # Modules de la barre et petites commandes du bureau : le même programme Rust, sans fenêtre
  # (panneaux/src/barre.rs) — instantané, sans aucun script.
  #   capteurs cpu|gpu|ram|temp  mesures de la barre (infobulles : applications les plus gourmandes)
  #   notifs                     cloche des notifications (survol : les dernières, par application)
  #   etat                       témoin "veille auto désactivée" (café) / "arrêt programmé" (sablier)
  #   reduites-barre             témoin des fenêtres réduites
  #   volume up|down|mute        touches multimédia + petite notification avec jauge
  #   veille-auto                appelé par hypridle (pas de veille si désactivée ou si l'IA travaille)
  #   capture-ecran [ecran]      capture façon KDE : zone (ou écran entier), puis aperçu
  #   lanceur                    Rofi ; relancer le referme, un clic ailleurs aussi (attrape-clic)
  capteurs = panneau "capteurs";
  notifsBarre = panneau "notifs";
  etatBarre = panneau "etat";
  reduitesBarre = panneau "reduites-barre";
  volume = panneau "volume";
  veilleAuto = panneau "veille-auto";
  capture = panneau "capture-ecran";
  lanceur = panneau "lanceur";

  # Apparence du lanceur d'applications (Rofi)
  rofiTheme = pkgs.writeText "neon.rasi" ''
    * {
        bg: #${c.bg}f2;
        surface: #${c.surface};
        surface2: #${c.surface2};
        text: #${c.text};
        muted: #${c.muted};
        magenta: #${c.magenta};
        cyan: #${c.cyan};

        font: "${font} 12";
        background-color: transparent;
        text-color: @text;
    }
    window {
        width: 36em;
        background-color: @bg;
        border: 2px;
        border-color: @magenta;
        border-radius: 12px;
    }
    mainbox {
        padding: 14px;
        spacing: 12px;
        children: [ inputbar, message, listview ];
    }
    inputbar {
        background-color: @surface;
        border-radius: 10px;
        padding: 10px 14px;
        spacing: 10px;
        children: [ prompt, entry ];
    }
    prompt {
        text-color: @cyan;
    }
    entry {
        placeholder: "Rechercher…";
        placeholder-color: @muted;
    }
    /* Zone de texte libre : calendrier, exemples de l'arrêt programmé */
    message {
        background-color: @surface;
        border-radius: 10px;
        padding: 10px 14px;
    }
    textbox {
        text-color: @text;
    }
    listview {
        lines: 8;
        columns: 1;
        spacing: 4px;
        scrollbar: false;
        fixed-height: false;
    }
    element {
        padding: 8px 12px;
        spacing: 12px;
        border-radius: 8px;
    }
    element selected.normal {
        background-color: @surface2;
        text-color: @cyan;
        border: 0 0 0 3px;
        border-color: @magenta;
    }
    element-icon {
        size: 1.4em;
    }
    element-text {
        vertical-align: 0.5;
        text-color: inherit;
    }
  '';

in
{
  # ---------------------------------------------------------------------------
  # 3. Waybar : la barre du haut (la seule barre)
  # Disposition inspirée de garuda-hyprdots : modules en "pilules" arrondies.
  # ---------------------------------------------------------------------------
  programs.waybar = {
    enable = true;
    systemd.enable = true; # démarre avec la session, redémarre après un nrsf

    # --- Contenu : quels modules, dans quel ordre, et ce que fait un clic ------
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = hauteurBarre;

      modules-left = [ "custom/launcher" "hyprland/workspaces" ];
      modules-center = [ "hyprland/window" ];
      modules-right = [ "custom/reduites" "tray" "pulseaudio" "custom/cpu" "custom/gpu" "custom/ram" "custom/temp" "network" "custom/notifications" "custom/etat" "clock" "custom/power" ];

      # Logo NixOS : ouvre le lanceur (comme Super+Espace)
      "custom/launcher" = {
        format = ic "f313";
        on-click = "${lanceur}";
        tooltip = false;
      };

      "hyprland/workspaces" = {
        format = "{id}";
        on-click = "activate";
        persistent-workspaces."*" = 5; # toujours afficher 1 à 5
      };

      # Titre de la fenêtre active
      "hyprland/window" = {
        max-length = 60;
        separate-outputs = true;
      };

      # Icônes des applis en arrière-plan (Steam, Discord, OpenSnitch, EasyEffects...)
      # Fenêtres réduites (bouton "réduire" ou Super+N). Clic = la liste, pour les ramener.
      "custom/reduites" = {
        exec = "${reduitesBarre}";
        return-type = "json";
        interval = 5;
        signal = 9; # rafraîchi tout de suite à chaque réduction
        on-click = "${panneau "reduites"}";
      };

      tray = {
        icon-size = 16;
        spacing = 8;
      };

      # Clic = panneau du son ; clic droit = couper le son ; molette = volume
      pulseaudio = {
        format = "{icon}  {volume}%";
        format-muted = "${ic "f026"}  muet";
        format-icons = {
          headphone = ic "f025";
          headset = ic "f025";
          default = [ (ic "f027") (ic "f028") ];
        };
        scroll-step = 2;
        on-click = "${panneau "son"}";
        on-click-right = "${volume} mute";
      };

      # Clic sur CPU ou RAM = moniteur système
      # Processeur, carte graphique, mémoire : survol = détail + applications les plus gourmandes.
      # Clic = moniteur système. Les mesures viennent de panneaux/src/barre.rs.
      "custom/cpu" = {
        exec = "${capteurs} cpu";
        return-type = "json";
        interval = 3;
        on-click = "${pkgs.kdePackages.plasma-systemmonitor}/bin/plasma-systemmonitor";
      };
      "custom/gpu" = {
        exec = "${capteurs} gpu";
        return-type = "json";
        interval = 3;
        on-click = "${pkgs.kdePackages.plasma-systemmonitor}/bin/plasma-systemmonitor";
      };
      "custom/ram" = {
        exec = "${capteurs} ram";
        return-type = "json";
        interval = 3;
        on-click = "${pkgs.kdePackages.plasma-systemmonitor}/bin/plasma-systemmonitor";
      };

      # Température de la carte graphique : la couleur suit la chaleur (vert, jaune, orange,
      # rouge ; seuils dans panneaux/src/barre.rs). Survol = détail, avec la température du processeur.
      "custom/temp" = {
        exec = "${capteurs} temp";
        return-type = "json";
        interval = 3;
      };

      # Clic = panneau réseau et Bluetooth (Wi-Fi, mode avion, filaire, appareils)
      network = {
        format-ethernet = "${ic "f0200"}  Filaire";
        format-wifi = "${ic "f1eb"}  {essid}";
        format-disconnected = "${ic "f071"}  Hors ligne";
        tooltip-format = "{ifname} : {ipaddr}/{cidr}";
        on-click = "${panneau "reseau"}";
      };

      # Cloche des notifications : nombre de nouvelles notifications ; clic = l'historique,
      # par application, avec la date et l'heure. Cloche barrée = "Ne pas déranger" actif.
      "custom/notifications" = {
        exec = "${notifsBarre}";
        return-type = "json";
        interval = 15;
        signal = 10; # rafraîchi à chaque notification et à l'ouverture du panneau
        on-click = "${panneau "notifications"}";
      };

      # Témoin "veille auto désactivée" / "arrêt programmé" (invisible le reste du temps)
      "custom/etat" = {
        exec = "${etatBarre}";
        return-type = "json";
        interval = 30;
        signal = 8; # rafraîchi immédiatement par le menu session
        on-click = "${panneau "session"}";
      };

      # Date, heure et secondes. Clic = calendrier ; survol = mois en cours.
      clock = {
        interval = 1;
        format = "${ic "f073"}  {:L%a %d %b   %H:%M:%S}";
        on-click = "${panneau "calendrier"}";
        tooltip-format = "<tt><small>{calendar}</small></tt>";
        calendar = {
          mode = "month";
          weeks-pos = "right";
          format = {
            months = "<span color='#${c.cyan}'><b>{}</b></span>";
            days = "<span color='#${c.text}'>{}</span>";
            weeks = "<span color='#${c.muted}'>S{}</span>";
            weekdays = "<span color='#${c.violet}'><b>{}</b></span>";
            today = "<span color='#${c.magenta}'><b><u>{}</u></b></span>";
          };
        };
      };

      # Bouton rouge : menu session (éteindre, redémarrer, veille, arrêt programmé, veille auto)
      "custom/power" = {
        format = ic "f011";
        on-click = "${panneau "session"}";
        tooltip = false;
      };
    };

    # --- Apparence (CSS) --------------------------------------------------------
    style = ''
      @define-color bg #${c.bg};
      @define-color surface #${c.surface};
      @define-color surface2 #${c.surface2};
      @define-color text #${c.text};
      @define-color muted #${c.muted};
      @define-color magenta #${c.magenta};
      @define-color cyan #${c.cyan};
      @define-color violet #${c.violet};
      @define-color yellow #${c.yellow};
      @define-color green #${c.green};
      @define-color orange #${c.orange};
      @define-color red #${c.red};

      * {
          border: none;
          border-radius: 0;
          min-height: 0;
          font-family: "${font}", sans-serif;
          font-size: 14px;
          font-weight: bold;
      }

      /* Piloté par "barreTransparente" tout en haut du fichier */
      window#waybar {
          background: ${if barreTransparente then "transparent" else "@bg"};
          color: @text;
      }

      /* --- Les pilules ------------------------------------------------------ */
      #custom-launcher,
      #workspaces,
      #window,
      #clock,
      #tray,
      #custom-reduites,
      #pulseaudio,
      #custom-cpu,
      #custom-gpu,
      #custom-ram,
      #custom-temp,
      #network,
      #custom-notifications,
      #custom-etat,
      #custom-power {
          background: @surface;
          margin: 7px 0;
          padding: 0 12px;
          border-radius: 10px;
      }

      /* --- Gauche ----------------------------------------------------------- */
      #custom-launcher {
          background: @magenta;
          color: @bg;
          font-size: 17px;
          margin-left: 12px;
          padding: 0 18px 0 11px; /* logo décalé vers la droite dans la police : marges inégales pour le recentrer */
      }

      #workspaces {
          margin-left: 8px;
          padding: 0 4px;
      }

      #workspaces button {
          color: @muted;
          background: transparent;
          padding: 0 7px;
          box-shadow: none;
          text-shadow: none;
      }

      #workspaces button.empty {
          color: @surface2;
      }

      #workspaces button.active {
          color: @cyan;
          text-shadow: 0 0 8px alpha(@cyan, 0.8);
      }

      #workspaces button.urgent {
          color: @red;
      }

      #workspaces button:hover {
          color: @magenta;
          background: transparent;
      }

      /* --- Centre ----------------------------------------------------------- */
      #window {
          color: @violet;
      }

      /* Pas de pilule vide quand aucune fenêtre n'est ouverte */
      window#waybar.empty #window {
          background: transparent;
      }

      /* --- Droite : son / CPU / RAM / température collés en un seul bloc ------ */
      #custom-reduites {
          color: @cyan;
          margin-right: 8px;
      }

      #tray {
          margin-right: 8px;
      }

      #pulseaudio {
          color: @magenta;
          border-radius: 10px 0 0 10px;
      }

      #pulseaudio.muted {
          color: @muted;
      }

      #custom-cpu {
          color: @cyan;
          border-radius: 0;
      }

      #custom-gpu {
          color: @orange;
          border-radius: 0;
      }

      #custom-ram {
          color: @violet;
          border-radius: 0;
      }

      #custom-temp {
          border-radius: 0 10px 10px 0;
      }

      /* Couleur des températures selon la chaleur (classe donnée par panneaux/src/barre.rs) */
      #custom-temp.froid { color: @green; }
      #custom-temp.tiede { color: @yellow; }
      #custom-temp.chaud { color: @orange; }
      #custom-temp.critique { color: @red; }

      #network {
          color: @yellow;
          margin-left: 8px;
      }

      #network.disconnected {
          color: @red;
      }

      /* Les cloches débordent à droite de leur case dans la police : marge droite plus grande
         pour les recentrer (mesuré : +2 px la cloche simple, +4 px celles qui sonnent ou barrées) */
      #custom-notifications {
          color: @text;
          margin-left: 8px;
          padding: 0 14px 0 12px;
      }

      #custom-notifications.dnd {
          color: @muted;
          padding: 0 16px 0 12px;
      }

      /* Notifications non lues : la cloche qui sonne, en cyan */
      #custom-notifications.nonlues {
          color: @cyan;
          padding: 0 16px 0 12px;
      }

      /* Option "clocheAnimee" : elle s'agite de gauche à droite avec un halo, se repose un
         instant, et recommence jusqu'à l'ouverture du panneau */
      #custom-notifications.animee {
          animation: sonner 2.4s ease-in-out infinite;
      }

      @keyframes sonner {
          0%   { padding: 0 16px 0 12px; text-shadow: 0 0 0 transparent; }
          6%   { padding: 0 19px 0 9px;  text-shadow: 0 0 8px @cyan; }
          12%  { padding: 0 13px 0 15px; text-shadow: 0 0 8px @cyan; }
          18%  { padding: 0 18px 0 10px; text-shadow: 0 0 8px @cyan; }
          24%  { padding: 0 14px 0 14px; text-shadow: 0 0 6px @cyan; }
          30%  { padding: 0 17px 0 11px; text-shadow: 0 0 4px @cyan; }
          36%  { padding: 0 16px 0 12px; text-shadow: 0 0 0 transparent; }
          100% { padding: 0 16px 0 12px; text-shadow: 0 0 0 transparent; }
      }

      #custom-etat {
          color: @orange;
          margin-left: 8px;
          /* La tasse est dessinée décalée vers la droite : marges inégales pour la recentrer */
          padding: 0 15px 0 9px;
      }

      #clock {
          color: @cyan;
          text-shadow: 0 0 8px alpha(@cyan, 0.5);
          margin-left: 8px;
      }

      #custom-power {
          background: @red;
          color: @bg;
          font-size: 16px;
          margin-left: 8px;
          margin-right: 12px;
          padding: 0 15px 0 13px;
      }

      /* --- Infobulles et menus (zone de notification) ------------------------ */
      tooltip {
          background: @bg;
          border: 1px solid @magenta;
          border-radius: 8px;
      }

      tooltip label {
          color: @text;
          padding: 2px 4px;
      }

      menu {
          background: @bg;
          color: @text;
          border: 1px solid @surface2;
          border-radius: 8px;
      }

      menuitem:hover {
          background: @surface2;
          color: @cyan;
      }
    '';
  };

  # ---------------------------------------------------------------------------
  # 4. Hyprland
  # ---------------------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    # Format de configuration : Lua (hyprland.lua). L'ancien format "hyprlang"
    # (hyprland.conf) est déclaré obsolète depuis Hyprland 0.55 et affiche un avertissement.
    # Référence : https://wiki.hypr.land/Configuring/Start/
    configType = "lua";
    package = null; # déjà installé par programs.hyprland (desktop.nix)
    portalPackage = null;

    # Le texte ci-dessous est du Lua, recopié tel quel dans ~/.config/hypr/hyprland.lua.
    # Les ''${...} sont remplacés par Nix (couleurs, chemins des programmes).
    # (d'autres fichiers peuvent y ajouter des lignes : voir applis.nix pour la dictée)
    extraConfig = lib.mkBefore ''
      local mod = "SUPER" -- la touche Windows

      -- Raccourci d'écriture : lancer("commande") = "exécuter cette commande"
      local function lancer(commande)
        return hl.dsp.exec_cmd(commande)
      end

      -- Écrans : échelle 1.5 sur tous les écrans (4K)
      hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "1.5" })

      hl.env("XCURSOR_THEME", "Adwaita")
      hl.env("XCURSOR_SIZE", "24")

      -- Thème des applications Qt/KDE (Dolphin...) : réglé dans le bloc "qt" plus bas.
      -- Ces variables doivent être données ici : la session démarre sans lire le fichier
      -- de variables de home-manager, et les applis lancées par Hyprland n'en héritaient pas.
      hl.env("QT_QPA_PLATFORMTHEME", "${config.home.sessionVariables.QT_QPA_PLATFORMTHEME}")
      hl.env("QT_STYLE_OVERRIDE", "${config.home.sessionVariables.QT_STYLE_OVERRIDE}")

      -- Applications XWayland (Steam, jeux Proton) : affichées à la résolution réelle de l'écran
      -- au lieu d'être dessinées en petit puis agrandies (ce qui les rendait floues/pixelisées).
      -- Steam grossit lui-même son interface pour rester lisible à l'échelle 1.5.
      hl.env("STEAM_FORCE_DESKTOPUI_SCALING", "${toString steamTaille}") -- réglage "steamTaille" en haut du fichier
      hl.config({ xwayland = { force_zero_scaling = true } })

      -- Lancé une fois à l'ouverture de session : seulement le fond d'écran.
      -- Le reste (barre, notifications, veille, applis) est déclaré dans startup.nix.
      hl.on("hyprland.start", function()
        hl.exec_cmd("${pkgs.swaybg}/bin/swaybg -m fill -i ${wallpaper}")
      end)

      hl.config({
        -- Clavier : repris de localisation.nix (disposition, comportement de Verr. Maj)
        input = {
          kb_layout = "${layout}",
          kb_variant = "${osConfig.services.xserver.xkb.variant}",
          kb_model = "${osConfig.services.xserver.xkb.model}",
          kb_options = "${osConfig.services.xserver.xkb.options},verrmaj:ponctuation", -- verrmaj : voir clavier/verrmaj
          numlock_by_default = true,

          -- Défilement au clic molette dans TOUTES les applications : maintenir la molette
          -- enfoncée (bouton du milieu) et bouger la souris fait défiler la page.
          -- Un simple clic molette, sans bouger, reste un clic du milieu (ouvrir un lien dans
          -- un nouvel onglet) ; il ne colle plus rien (misc.middle_click_paste, plus bas).
          -- Et un simple clic molette lance le défilement automatique façon Windows (voir les
          -- raccourcis souris plus bas : "defilement").
          scroll_method = "on_button_down",
          scroll_button = 274, -- 274 = bouton du milieu (la molette)
          -- Distance parcourue par cran de molette : 1.0 = normal, 2.0 = deux fois plus.
          scroll_factor = ${toString defilement},
        },

        general = {
          gaps_in = 5, -- espace entre deux fenêtres
          gaps_out = 10, -- espace entre les fenêtres et le bord de l'écran
          border_size = 2,
          col = {
            active_border = "rgb(${c.cyan})", -- fenêtre active (sous la souris) : bleu clair
            inactive_border = "rgb(${c.surface2})",
          },
          resize_on_border = true, -- redimensionner en attrapant le bord à la souris
          -- Disposition "défilante", comme Niri : les fenêtres sont des colonnes posées sur un
          -- ruban infini qui défile de gauche à droite. Ouvrir une fenêtre ne rétrécit pas les
          -- autres : elle s'ajoute à droite. (Ancienne disposition en mosaïque : "dwindle".)
          layout = "scrolling",
        },

        -- Réglages de la disposition défilante
        scrolling = {
          column_width = 0.5, -- largeur d'une nouvelle colonne (0.5 = moitié de l'écran)
          explicit_column_widths = "0.333, 0.5, 0.667, 1.0", -- largeurs proposées par Super+R
          fullscreen_on_one_column = true, -- une fenêtre seule prend tout l'écran
          focus_fit_method = 1, -- la colonne choisie est ramenée entièrement à l'écran
          follow_focus = true,
        },

        decoration = {
          rounding = 10,
          inactive_opacity = 0.95, -- 1.0 = fenêtres inactives totalement opaques
          blur = { enabled = true, size = 8, passes = 3, vibrancy = 0.3 },
          -- Halo néon autour de la fenêtre active
          shadow = {
            enabled = true,
            range = 24,
            render_power = 2,
            color = "rgba(${c.cyan}55)",
            color_inactive = "rgba(00000066)",
          },
        },

        animations = { enabled = true },

        -- La souris ne saute jamais toute seule d'une fenêtre à l'autre (par exemple vers
        -- Firefox quand un lien est ouvert depuis Discord) : elle reste là où tu l'as laissée.
        cursor = { no_warps = true },

        misc = {
          disable_hyprland_logo = true,
          disable_splash_rendering = true,
          focus_on_activate = true, -- une appli qui demande l'attention passe au premier plan
          vrr = 2, -- fréquence d'image variable (FreeSync), seulement en plein écran
          -- Clic molette : plus de "coller" (sélection collée au clic du milieu, habitude Linux).
          -- Le clic molette sert au défilement, comme sous Windows (voir "input" plus haut).
          middle_click_paste = false,
        },
      })

      -- Animations
      hl.curve("fluide", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.0 } } })
      hl.animation({ leaf = "windows", enabled = true, speed = 5, bezier = "fluide", style = "popin 80%" })
      hl.animation({ leaf = "windowsOut", enabled = true, speed = 5, bezier = "default", style = "popin 80%" })
      hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
      hl.animation({ leaf = "fade", enabled = true, speed = 6, bezier = "default" })
      hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "fluide", style = "slide" })

      -- Flou derrière la barre, le lanceur, les notifications et les panneaux
      hl.layer_rule({
        name = "flou",
        match = { namespace = "^(waybar|rofi|notifications|panneau|alttab)$" },
        blur = true,
        ignore_alpha = 0.3,
      })
      -- Capture d'écran : la photo figée de l'écran apparaît d'un coup, sans animation
      -- (sinon on la verrait glisser ou s'estomper, et l'écran ne paraîtrait pas figé)
      hl.layer_rule({
        name = "capture-instantanee",
        match = { namespace = "^(selection|defilement)$" }, -- capture, icône du défilement automatique
        no_anim = true,
      })

      -- Petites fenêtres utilitaires : flottantes plutôt qu'en mosaïque
      hl.window_rule({
        name = "flottantes",
        match = { class = "^(org.pulseaudio.pavucontrol|org.keepassxc.KeePassXC|qalculate-qt)$" },
        float = true,
      })
      -- Mélangeur complet : taille correcte, au centre (Super+clic gauche pour le déplacer)
      hl.window_rule({
        name = "melangeur",
        match = { class = "^(org.pulseaudio.pavucontrol)$" },
        size = "1000 650",
        center = true,
      })
      -- Un jeu ou une vidéo en plein écran empêche l'écran et l'ordi de se mettre en veille
      hl.window_rule({ name = "pas-de-veille", match = { class = ".*" }, idle_inhibit = "fullscreen" })
      -- Discord en arrière-plan : Hyprland continue de lui envoyer des images même quand il
      -- n'est pas visible. Sans cela, Discord se met en "veille" et les appels peuvent couper.
      hl.window_rule({ name = "discord-eveille", match = { class = "^(discord|discordptb|[Vv]esktop|[Ee]quibop)$" }, render_unfocused = true })

      -- -----------------------------------------------------------------------
      -- Raccourcis (la liste lisible est tout en haut de desktop-home.nix)
      -- -----------------------------------------------------------------------
      hl.bind(mod .. " + Return", lancer("${terminalBin}"))
      hl.bind(mod .. " + E", lancer("${pkgs.kdePackages.dolphin}/bin/dolphin"))
      hl.bind(mod .. " + Q", hl.dsp.window.close())
      hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
      hl.bind(mod .. " + M", hl.dsp.window.fullscreen({ mode = "maximized" })) -- garde la barre
      hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
      hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())

      -- Hyprland n'a pas de barre des tâches, donc pas de vrai bouton "réduire" :
      -- on range la fenêtre dans un espace caché, qu'on affiche ou cache à la demande.
      hl.bind(mod .. " + N", hl.dsp.window.move({ workspace = "special:reduites", follow = false }))
      hl.bind(mod .. " + SHIFT + N", hl.dsp.workspace.toggle_special("reduites"))

      hl.bind(mod .. " + space", lancer("${lanceur}"))
      hl.bind(mod .. " + D", lancer("${lanceur}"))
      hl.bind(mod .. " + X", lancer("${panneau "session"}"))
      hl.bind(mod .. " + C", lancer("${panneau "calendrier"}"))
      hl.bind(mod .. " + L", lancer("hyprlock"))
      hl.bind(mod .. " + B", lancer("pkill -SIGUSR1 waybar")) -- afficher / masquer la barre
      hl.bind("Print", lancer("${capture}")) -- une zone
      hl.bind("SHIFT + Print", lancer("${capture} ecran")) -- l'écran entier

      -- Flèches : Super = changer de fenêtre (colonne à gauche / à droite, fenêtre au-dessus /
      -- en dessous dans la même colonne)
      for _, direction in ipairs({ "left", "right", "up", "down" }) do
        hl.bind(mod .. " + " .. direction, hl.dsp.focus({ direction = direction }))
      end
      -- Super+Maj : déplacer la colonne entière vers la gauche / la droite, ou la fenêtre
      -- vers le haut / le bas dans sa colonne
      hl.bind(mod .. " + SHIFT + left", hl.dsp.layout("swapcol l"))
      hl.bind(mod .. " + SHIFT + right", hl.dsp.layout("swapcol r"))
      hl.bind(mod .. " + SHIFT + up", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + SHIFT + down", hl.dsp.window.move({ direction = "down" }))
      -- Super+Ctrl : élargir / rétrécir la colonne, ou agrandir / réduire la hauteur
      hl.bind(mod .. " + CTRL + left", hl.dsp.layout("colresize -0.05"), { repeating = true })
      hl.bind(mod .. " + CTRL + right", hl.dsp.layout("colresize +0.05"), { repeating = true })
      hl.bind(mod .. " + CTRL + up", hl.dsp.window.resize({ x = 0, y = -60, relative = true }), { repeating = true })
      hl.bind(mod .. " + CTRL + down", hl.dsp.window.resize({ x = 0, y = 60, relative = true }), { repeating = true })
      -- Super+R : passer la colonne à la largeur suivante (1/3, 1/2, 2/3, tout l'écran)
      hl.bind(mod .. " + R", hl.dsp.layout("colresize +conf"))
      -- Super+, : glisser la fenêtre dans la colonne de gauche (ou l'en sortir)
      -- Super+; : même chose vers la droite
      hl.bind(mod .. " + comma", hl.dsp.layout("consume_or_expel prev"))
      hl.bind(mod .. " + semicolon", hl.dsp.layout("consume_or_expel next"))
      -- Super + molette : faire défiler le ruban de colonnes
      hl.bind(mod .. " + mouse_down", hl.dsp.layout("move +col"))
      hl.bind(mod .. " + mouse_up", hl.dsp.layout("move -col"))

      -- Espaces de travail : Super+1..9 pour y aller, Super+Maj+1..9 pour y envoyer la fenêtre.
      -- "code:10" à "code:18" = les touches de la rangée du haut, par leur position : en AZERTY,
      -- sans Maj, elles donnent & é " ' ( - è _ ç et non des chiffres, donc "Super+1" écrit
      -- tel quel ne correspondait à aucune touche.
      for i = 1, 9 do
        hl.bind(mod .. " + code:" .. (9 + i), hl.dsp.focus({ workspace = i }))
        hl.bind(mod .. " + SHIFT + code:" .. (9 + i), hl.dsp.window.move({ workspace = i }))
      end

      -- -----------------------------------------------------------------------
      -- Alt+Tab, comme sous Niri ou Windows : maintenir Alt, Tab pour passer à la fenêtre
      -- suivante (Maj+Tab : précédente, ou les flèches), relâcher Alt pour y aller ; Échap
      -- annule. Les fenêtres sont dans l'ordre où tu les as utilisées, avec leurs miniatures.
      -- La logique est ici, dans Hyprland (instantanée, même en tapotant vite) ; l'affichage
      -- des miniatures est fait par le programme panneaux (panneaux/src/alttab.rs), qui suit la sélection.
      -- -----------------------------------------------------------------------
      AltTab = { liste = {}, index = 1, actif = false, session = 0 }
      local fichierAltTab = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/alttab-choix"

      -- La fenêtre choisie est écrite dans un petit fichier, lu par l'affichage
      local function altTabEcrire(texte)
        local f = io.open(fichierAltTab, "w")
        if f then
          f:write(texte)
          f:close()
        end
      end

      -- Toutes les fenêtres (fenêtres réduites comprises), de la plus récemment utilisée
      -- à la plus ancienne
      local function altTabListe()
        local liste = {}
        for _, w in ipairs(hl.get_windows()) do
          local espace = (w.workspace and w.workspace.name) or ""
          if w.mapped and (espace == "special:reduites" or not espace:match("^special:")) then
            table.insert(liste, w)
          end
        end
        table.sort(liste, function(a, b) return a.focus_history_id < b.focus_history_id end)
        return liste
      end

      function AltTab.finir(choisir)
        if not AltTab.actif then return end
        AltTab.actif = false
        altTabEcrire("fin")
        hl.dispatch(hl.dsp.submap("reset"))
        local w = AltTab.liste[AltTab.index]
        if not (choisir and w) then return end
        local cible = "address:" .. w.address
        if w.workspace and w.workspace.name == "special:reduites" then
          -- fenêtre réduite : la ramener sur l'espace de travail affiché
          hl.dispatch(hl.dsp.window.move({ window = cible, workspace = hl.get_active_workspace().id }))
          hl.exec_cmd("pkill -RTMIN+9 waybar")
        end
        hl.dispatch(hl.dsp.focus({ window = cible }))
      end

      function AltTab.avancer(sens)
        if not AltTab.actif then
          AltTab.liste = altTabListe()
          if #AltTab.liste < 2 then return end -- 0 ou 1 fenêtre : rien à choisir
          AltTab.actif = true
          AltTab.index = 1
          AltTab.session = AltTab.session + 1
          local session = AltTab.session
          hl.dispatch(hl.dsp.submap("alttab"))
          hl.exec_cmd("${panneau "alttab"}")
          -- Sécurité : on ne reste jamais plus de 30 s dans ce mode
          hl.timer(function()
            if AltTab.session == session then AltTab.finir(false) end
          end, { timeout = 30000, type = "oneshot" })
        end
        AltTab.index = (AltTab.index - 1 + sens) % #AltTab.liste + 1
        altTabEcrire(AltTab.liste[AltTab.index].address)
      end

      -- Clic sur une miniature (appelé par le programme panneaux)
      function AltTab.choisir(adresse)
        for i, w in ipairs(AltTab.liste) do
          if w.address == adresse then AltTab.index = i end
        end
        AltTab.finir(true)
      end

      hl.bind("ALT + Tab", function() AltTab.avancer(1) end)
      hl.bind("ALT + SHIFT + Tab", function() AltTab.avancer(-1) end)
      -- Relâcher Alt = aller à la fenêtre choisie.
      --   non_consuming : la touche Alt continue d'arriver aux applications (sinon Alt ne
      --                   marcherait plus nulle part) ;
      --   transparent   : indispensable. Pendant qu'on tient Alt, l'appui sur Tab "masque" les
      --                   raccourcis de la touche Alt (règle de Hyprland, pour que relâcher Super
      --                   après Super+Q ne lance rien) : sans cette option, relâcher Alt ne
      --                   ferait rien et il fallait cliquer sur la miniature.
      -- (Ce raccourci est global, pas dans le mode "alttab" : Hyprland ne retient un relâchement
      --  que dans le mode où la touche a été enfoncée, et Alt l'est toujours avant d'y entrer.)
      hl.bind("ALT + Alt_L", function() AltTab.finir(true) end, { release = true, non_consuming = true, transparent = true })
      -- Pendant le choix seulement :
      hl.define_submap("alttab", function()
        hl.bind("ALT + Tab", function() AltTab.avancer(1) end)
        hl.bind("ALT + SHIFT + Tab", function() AltTab.avancer(-1) end)
        hl.bind("ALT + right", function() AltTab.avancer(1) end)
        hl.bind("ALT + left", function() AltTab.avancer(-1) end)
        hl.bind("ALT + Return", function() AltTab.finir(true) end)
        hl.bind("ALT + Escape", function() AltTab.finir(false) end)
        hl.bind("Escape", function() AltTab.finir(false) end)
      end)

      -- Défilement automatique façon Windows (panneaux/src/defilement.rs) : un clic molette le
      -- démarre (ou l'arrête) ; un clic gauche ou droit, ou Échap, l'arrête aussi. Pour
      -- l'arrêter, Hyprland efface simplement son fichier témoin : aucun programme n'est lancé
      -- à chaque clic. "non_consuming" : les applications reçoivent quand même leurs clics.
      local temoinDefilement = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/defilement-auto"
      local function arreterDefilement()
        os.remove(temoinDefilement)
      end
      hl.bind("mouse:274", hl.dsp.exec_cmd("${panneau "defilement"}"), { non_consuming = true })
      hl.bind("mouse:272", arreterDefilement, { non_consuming = true })
      hl.bind("mouse:273", arreterDefilement, { non_consuming = true })
      hl.bind("Escape", arreterDefilement, { non_consuming = true })

      -- Super + clic gauche = déplacer ; Super + clic droit = redimensionner
      hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
      hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

      -- Volume : "repeating" = se répète si on maintient ; "locked" = marche aussi écran verrouillé
      hl.bind("XF86AudioRaiseVolume", lancer("${volume} up"), { repeating = true, locked = true })
      hl.bind("XF86AudioLowerVolume", lancer("${volume} down"), { repeating = true, locked = true })
      hl.bind("XF86AudioMute", lancer("${volume} mute"), { locked = true })
    '';
  };

  # ---------------------------------------------------------------------------
  # 5. Le reste
  # ---------------------------------------------------------------------------

  # --- Lanceur d'applications (Super+Espace) -----------------------------------
  # Le menu session et le calendrier utilisent le même programme et le même thème.
  programs.rofi = {
    enable = true;
    terminal = terminalBin;
    theme = "${rofiTheme}";
    extraConfig = {
      modi = "drun,run"; # drun = applications installées ; run = n'importe quelle commande
      show-icons = true;
      icon-theme = "Papirus-Dark";
      display-drun = ic "f002";
      drun-display-format = "{name}";
      # La sélection suit la souris, et un seul clic lance l'application
      hover-select = true;
      me-select-entry = "";
      me-accept-entry = "MousePrimary";
    };
  };

  # --- Partage d'écran (Discord, navigateurs...) --------------------------------
  # Le portail de Hyprland ouvre notre sélecteur, dans le style des panneaux, au lieu du sien.
  # "Se souvenir de ce choix" est coché d'office : une application qui sait s'en servir ne
  # redemande pas à chaque partage.
  xdg.configFile."hypr/xdph.conf" = {
    text = ''
      screencopy {
          custom_picker_binary = ${selecteurPartage}
          allow_token_by_default = true
      }
    '';
    # Le portail ne relit sa configuration qu'au démarrage
    onChange = "${pkgs.systemd}/bin/systemctl --user try-restart xdg-desktop-portal-hyprland.service || true";
  };

  # --- Notifications -----------------------------------------------------------
  services.mako = {
    enable = true;
    settings = {
      font = "${font} 11";
      anchor = "top-right";
      width = 380;
      margin = "12";
      padding = "12";
      border-size = 2;
      border-radius = 10;
      background-color = "#${c.surface}ee";
      text-color = "#${c.text}";
      border-color = "#${c.cyan}";
      progress-color = "over #${c.magenta}55"; # jauge du volume
      default-timeout = 5000; # en millisecondes

      # Petit son à chaque notification (réglage "sonNotification" en haut du fichier)
      on-notify = lib.mkIf (sonNotification != "")
        "exec ${pkgs.pipewire}/bin/pw-play ${pkgs.kdePackages.ocean-sound-theme}/share/sounds/ocean/stereo/${sonNotification}.oga";

      # Mode "Ne pas déranger" (bouton du panneau des notifications) : rien ne s'affiche,
      # aucun son, mais tout reste dans l'historique de la cloche.
      "mode=do-not-disturb" = {
        invisible = 1;
        on-notify = "none";
      };

      # Les notifications urgentes restent affichées jusqu'à ce qu'on clique dessus
      "urgency=critical" = {
        border-color = "#${c.red}";
        default-timeout = 0;
      };
    }
    # Pas de son pour les applications qui ont le leur ("sansSonPour"), ni pour les
    # pastilles passagères du bureau (jauge du volume, dictée)
    // lib.genAttrs (map (appli: "app-name=${appli}") (sansSonPour ++ [ "volume" "dictee" ]))
      (_: { on-notify = "none"; });
  };

  # --- Veille automatique ------------------------------------------------------
  # Les délais se règlent tout en haut du fichier. Une vidéo en cours de lecture
  # ou une fenêtre en plein écran suspend ces minuteries.
  services.hypridle = {
    enable = true;
    settings = {
      # Au réveil de l'ordinateur : rallumer l'écran
      general.after_sleep_cmd = "${osConfig.programs.hyprland.package}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";

      listener = [
        # 1) Éteindre l'écran (toujours) ; il se rallume dès que tu bouges la souris
        {
          timeout = ecranEnVeilleApres * 60;
          on-timeout = "${osConfig.programs.hyprland.package}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = \"off\" })'";
          on-resume = "${osConfig.programs.hyprland.package}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'";
        }
        # 2) Mettre l'ordinateur en veille, sauf si c'est désactivé depuis le menu session
        {
          timeout = ordiEnVeilleApres * 60;
          on-timeout = "${veilleAuto}";
        }
      ];
    };
  };

  # --- Verrouillage (Super+L) --------------------------------------------------
  # Seulement à la demande : ni le démarrage ni le réveil ne demandent de mot de passe.
  programs.hyprlock = {
    enable = true;
    settings = {
      general.hide_cursor = true;

      background = [{
        monitor = "";
        path = "${wallpaper}";
        blur_passes = 3;
        brightness = 0.6;
      }];

      label = [{
        monitor = "";
        text = "$TIME";
        color = "rgb(${c.cyan})";
        font_size = 96;
        font_family = font;
        position = "0, 160";
        halign = "center";
        valign = "center";
      }];

      input-field = [{
        monitor = "";
        size = "360, 56";
        outline_thickness = 2;
        rounding = 10;
        outer_color = "rgb(${c.magenta}) rgb(${c.cyan}) 45deg";
        inner_color = "rgb(${c.surface})";
        font_color = "rgb(${c.text})";
        check_color = "rgb(${c.yellow})";
        fail_color = "rgb(${c.red})";
        placeholder_text = "Mot de passe";
        fade_on_empty = false;
        position = "0, -40";
        halign = "center";
        valign = "center";
      }];
    };
  };

  # Dossiers : toujours ouverts avec Dolphin ("ouvrir le dossier" depuis Firefox, Discord...)
  xdg.mimeApps = {
    enable = true;
    defaultApplications."inode/directory" = [ "org.kde.dolphin.desktop" ];
  };

  # --- Terminal : Kitty (Super+Entrée) ----------------------------------------
  programs.kitty = {
    enable = true;
    font = {
      name = font;
      size = 11;
    };
    settings = {
      background_opacity = "0.9"; # 1.0 = fond opaque
      window_padding_width = 8; # marge intérieure, en points
      confirm_os_window_close = 0; # ferme sans demander confirmation
      enable_audio_bell = false;
      update_check_interval = 0; # pas de vérification de mise à jour (c'est Nix qui gère)

      background = "#${c.bg}";
      foreground = "#${c.text}";
      cursor = "#${c.cyan}";
      selection_background = "#${c.surface2}";
      selection_foreground = "#${c.text}";
      url_color = "#${c.cyan}";
      active_border_color = "#${c.magenta}";
      inactive_border_color = "#${c.surface2}";

      color0 = "#${c.surface2}";
      color1 = "#${c.red}";
      color2 = "#${c.green}";
      color3 = "#${c.yellow}";
      color4 = "#${c.violet}";
      color5 = "#${c.magenta}";
      color6 = "#${c.cyan}";
      color7 = "#${c.text}";
      color8 = "#${c.muted}";
      color9 = "#${c.red}";
      color10 = "#${c.green}";
      color11 = "#${c.orange}";
      color12 = "#${c.violet}";
      color13 = "#${c.magenta}";
      color14 = "#${c.cyan}";
      color15 = "#ffffff";
    };
  };

  # --- Thème sombre partout (applis GTK et Qt) ---------------------------------
  gtk = {
    enable = true;
    theme = {
      name = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    gtk4.theme = config.gtk.theme; # même thème pour les applis GTK4
    gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
    # Boutons en haut à droite des fenêtres : réduire, agrandir, fermer.
    # "Réduire" range la fenêtre dans la barre du haut (voir desktop.nix et startup.nix).
    gtk3.extraConfig.gtk-decoration-layout = ":minimize,maximize,close";
    gtk4.extraConfig.gtk-decoration-layout = ":minimize,maximize,close";
    # Remplace les gtk.css laissés par KDE (ils réimposaient les couleurs de Plasma)
    gtk3.extraCss = "/* géré par home-manager (desktop-home.nix) */";
    gtk4.extraCss = "/* géré par home-manager (desktop-home.nix) */";
  };

  # Indique aux applis récentes (GTK4, Firefox, Electron) de préférer le mode sombre
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  # Même réglage des boutons de fenêtre, à l'endroit où les applis GTK le lisent sous Wayland.
  # Réduire = bouton de la fenêtre ou Super+N ; la fenêtre apparaît alors en haut à droite
  # de la barre, et un clic sur cette icône permet de la ramener.
  dconf.settings."org/gnome/desktop/wm/preferences".button-layout = ":minimize,maximize,close";

  # Applications Qt et KDE (Dolphin...) : comme sous KDE Plasma, elles lisent leurs couleurs
  # dans ~/.config/kdeglobals (plateforme "kde", style Breeze). L'ancien réglage "adwaita"
  # ignorait ce fichier et imposait une palette qui donnait des lignes blanches une sur deux.
  qt = {
    enable = true;
    platformTheme.name = "kde";
    style.name = "breeze";
  };
  # Couleurs "système" des applications KDE/Qt : Breeze sombre (le même que sous Plasma).
  # Les applis réglées sur "couleur du système" sont donc sombres d'office.
  xdg.configFile."kdeglobals" = {
    force = true; # remplace l'ancien fichier laissé par Plasma
    # (le fichier Breeze sombre contient déjà [General] ColorScheme=BreezeDark)
    text = builtins.readFile "${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors" + ''

      [KDE]
      LookAndFeelPackage=org.kde.breezedark.desktop
    '';
  };

  # --- Touches mortes (^ ¨) ----------------------------------------------------
  # Installe /etc/nixos/.XCompose dans ~/.XCompose, là où les applications le cherchent.
  # Verr. Maj « comme Windows » (ponctuation comprise, flèches non) : règle clavier sur mesure,
  # activée par l'option verrmaj:ponctuation de Hyprland (plus bas). Fichiers : clavier/.
  xdg.configFile."xkb/types/verrmaj".source = ./clavier/verrmaj;
  xdg.configFile."xkb/rules/evdev".source = ./clavier/evdev;

  home.file.".XCompose".source = ./.XCompose;

  # --- Divers ------------------------------------------------------------------
  services.hyprpolkitagent.enable = true; # fenêtres de demande de mot de passe administrateur (polkit)

  home.pointerCursor = {
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 24;
    gtk.enable = true;
  };

  home.packages = with pkgs; [
    grim # captures d'écran
    slurp # sélection de zone
    wl-clipboard # presse-papiers en ligne de commande
  ];
}
