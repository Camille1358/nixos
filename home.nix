# pkgs-unstable et spicetify-nix sont maintenant fournis par flake.nix
{ config, lib, pkgs, pkgs-unstable, spicetify-nix, ... }:

let
  local = import ./local.nix;

  # Options de lancement de Discord (et Discord PTB) :
  # - WebRTCPipeWireCapturer : partage d'écran et de fenêtre sous Wayland ;
  # - WaylandWindowDecorations : bordures de fenêtre (remis ici car cette liste remplace
  #   celle fournie par défaut) ;
  # - les trois "disable-background..." : Discord ne se met plus en veille quand il est en
  #   arrière-plan ou caché, ce qui coupait parfois les appels.
  discordOptions = lib.concatStringsSep " " [
    "--enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer"
    "--disable-background-timer-throttling"
    "--disable-renderer-backgrounding"
    "--disable-backgrounding-occluded-windows"
  ];

  # Clients Discord alternatifs (Vesktop, Equibop) : ils n'ont pas d'option pour leurs
  # paramètres de lancement ; on les enveloppe pour leur donner les mêmes que Discord.
  avecOptionsDiscord = paquet: nom: pkgs.symlinkJoin {
    name = "${nom}-avec-options";
    paths = [ paquet ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = "wrapProgram $out/bin/${nom} --add-flags ${lib.escapeShellArg discordOptions}";
  };
  equibopAvecOptions = avecOptionsDiscord pkgs.equibop "equibop";

  # Deuxième Equibop, sur la branche PTB de Discord : son propre dossier de données (ses comptes,
  # ses réglages), si bien qu'il tourne en même temps que le premier. Menu : "Equibop PTB".
  equibopPtb = pkgs.writeShellScriptBin "equibop-ptb" ''
    dossier="''${XDG_CONFIG_HOME:-$HOME/.config}/equibop-ptb"
    export EQUICORD_USER_DATA_DIR="$dossier"
    exec ${equibopAvecOptions}/bin/equibop --user-data-dir="$dossier" "$@"
  '';
in

{
  # Les autres fichiers utilisateur (bureau, IA, applis) sont déclarés dans modules/.
  imports = [ spicetify-nix.homeManagerModules.default ];
  home = {
    username = local.sysName; # Informations sur l'utilisateur
    homeDirectory = "/home/${local.sysName}";
    sessionVariables = {};
    packages = with pkgs; [
      # Paquets installés uniquement pour la session utilisateur
      #-----------------------------------------------APPs------------------------------------------------
      vlc
      vscode
      unzip
      keepassxc
      obs-studio
      fastfetch
      kdePackages.plasma-systemmonitor # plus fourni par KDE Plasma, donc ajouté ici
      kdePackages.ksystemstats # backend de données de plasma-systemmonitor
      # (Dolphin : dans desktop-home.nix, avec les aperçus des vidéos)
      kdePackages.spectacle
      tesseract
      nvtopPackages.amd
      pavucontrol
      sublime3
      qalculate-qt
      evince
      pkgs.opensnitch-ui
      qimgv
      vintagestory
      #----------------------------------------------Maths------------------------------------------------
      ffmpeg
      texlive.combined.scheme-full
      #----------------------------------------------Browser----------------------------------------------
      pkgs-unstable.tor-browser # dernière version possible "pkgs-unstable"
      pkgs-unstable.mullvad-browser # dernière version sur la stable "pkgs-stable-latest.mullvad-browser"
      pkgs-unstable.brave
      google-chrome
      #-----------------------------------------------Games-----------------------------------------------
      easyeffects
      # (lutris, heroic, mangohud, goverlay, protonup-qt, lact, gamescope, deadlock-mod-manager : voir games_drivers.nix)
      #---------------------------------------------------------------------------------------------------
      
      # Discord PTB + Vencord, et Discord + Vencord (options de lancement : voir en haut)
      (discord-ptb.override {
        withVencord = true;
        commandLineArgs = discordOptions;
      })
      (discord.override {
        withVencord = false;
        commandLineArgs = discordOptions;
      })

      # Clients Discord alternatifs, compilés depuis leur code source par nixpkgs (vérifiés le
      # 15/10/2026 : aucun signalement de malveillance). Vesktop : par l'équipe de Vencord.
      # Equibop : variante d'Equicord (plus de 300 extensions ; n'activer que celles dont on a
      # besoin). Legcord n'est PAS installé : deux failles critiques sans correctif
      # (CVE-2026-105293 et CVE-2026-105294, versions 1.1.0 à 1.3.0).
      (avecOptionsDiscord vesktop "vesktop")
      equibopAvecOptions
      equibopPtb # deuxième Equibop (branche PTB), voir plus haut
      # Spotify avec sa barre de titre (réduire, agrandir, fermer) : comme Discord, il ne la
      # dessine sous Wayland que si on le lui demande. Réduire = la fenêtre va dans la barre du
      # haut, à côté des autres. (Prioritaire sur le lanceur de spicetify, qui reste utilisé.)
      (lib.hiPrio (pkgs.writeShellScriptBin "spotify" ''
        exec ${config.programs.spicetify.spicedSpotify}/bin/spotify --enable-features=WaylandWindowDecorations "$@"
      ''))
    ];
  };

  # Deuxième Equibop dans le lanceur d'applications (Super+Espace)
  xdg.desktopEntries.equibop-ptb = {
    name = "Equibop PTB";
    genericName = "Discord (PTB)";
    exec = "${equibopPtb}/bin/equibop-ptb %U";
    icon = "equibop";
    categories = [ "Network" "InstantMessaging" ];
  };
  # Son dossier, préparé une seule fois (ensuite, tes réglages faits dans l'appli sont gardés) :
  # branche PTB, pas de Rich Presence (le premier Equibop s'en charge déjà ; deux à la fois se
  # disputeraient le même port), et une copie des extensions et thèmes Equicord du premier.
  home.activation.equibopPtb = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ptb="${config.xdg.configHome}/equibop-ptb"
    if [ ! -e "$ptb" ]; then
      run mkdir -p "$ptb"
      run cp -r --no-preserve=mode "${config.xdg.configHome}/equibop/settings" "$ptb/" 2>/dev/null || true
      run cp -r --no-preserve=mode "${config.xdg.configHome}/equibop/themes" "$ptb/" 2>/dev/null || true
      run sh -c 'echo "{\"discordBranch\": \"ptb\", \"minimizeToTray\": true, \"arRPC\": false}" > "$1/settings.json"' _ "$ptb"
      run sh -c 'echo "{\"firstLaunch\": false}" > "$1/state.json"' _ "$ptb"
    fi
  '';

  # VS Code : le clic molette ne colle rien. Seul ce réglage est ajouté à settings.json, le
  # reste (tes réglages faits dans VS Code) n'est pas touché. Relancer VS Code après nrs.
  home.activation.vscodeSansCollage = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    reglages="${config.xdg.configHome}/Code/User/settings.json"
    if [ -f "$reglages" ] && nouveau=$(${pkgs.jq}/bin/jq '.["editor.selectionClipboard"] = false' "$reglages" 2>/dev/null); then
      [ "$nouveau" = "$(cat "$reglages")" ] || run sh -c 'printf "%s\n" "$2" > "$1"' _ "$reglages" "$nouveau"
    fi
  '';

  programs.spicetify = let
    spicePkgs = spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  in {
    enable = true;
    theme = spicePkgs.themes.sleek;
    colorScheme = "Deeper";

    enabledExtensions = with spicePkgs.extensions; [
      hidePodcasts
      shuffle
      bookmark
      volumePercentage
    ];
  };


  # Configuration directe des logiciels
  programs.git = {
    enable = true;
    settings = {
      user.name = local.gitName;
      user.email = local.gitEmail;
    };
  };

  programs.firefox = {
    enable = true;
    configPath = ".mozilla/firefox";
    profiles.${local.sysName} = {
      isDefault = true;
      settings = {
        # Défilement automatique de Firefox (clic molette)
        "general.autoScroll" = true;
        # Le clic molette ne colle rien (Firefox gardait sa propre sélection et la recollait)
        "middlemouse.paste" = false;
        "clipboard.autocopy" = false;
        "privacy.resistFingerprinting" = false; # Protection contre le fingerprinting (+++FingerprintingResist, mais lourd sur l'ergo)
        "privacy.fingerprintingProtection" = false; # Protection contre le fingerprinting (+FingerprintingResist, alt moderne +leger)
        "dom.security.https_only_mode" = true; # Mode HTTPS (+confidentialité & sécurité)
        "privacy.donottrackheader.enabled" = false; # Désactive l'envoi de l'en-tête Do Not Track (+FingerprintingResist)
        "privacy.trackingprotection.enabled" = true; # Protection contre le tracking (+confidentialité)
        "datareporting.healthreport.uploadEnabled" = false; # Désactive l'envoi de rapports (+confidentialité)
        "app.normandy.enabled" = false; # Empêche Mozilla d'exécuter à distance des expérimentations ou des modifications (+confidentialité)
        "geo.enabled" = false; # Désactive la géolocalisation (+confidentialité)
        "media.peerconnection.ice.no_host" = true; # Désactive la découverte d'adresses IP locales via WebRTC (+confidentialité)
        "network.predictor.enabled" = false; # Désactive la prédiction de navigation (+confidentialité)
        "network.dns.disablePrefetch" = true; # Désactive la prélecture DNS (+confidentialité)
        "app.shield.optoutstudies.enabled" = false; # Empêche Mozilla de participer à des études de télémétrie (+confidentialité)
        "network.prefetch-next" = false; # Désactive la prélecture des liens (+confidentialité)
        "device.sensors.enabled" = false; # Désactive l'accès aux capteurs de l'appareil (+confidentialité)
        "dom.gamepad.enabled" = false; # Empêche la détection et l'énumération de manettes connectées. (+confidentialité)
        "browser.cache.disk.enable" = false; # Bascule du cache disque vers la RAM (1 Go max)
        "browser.cache.memory.enable" = true;
        "browser.cache.memory.capacity" = 1048576;
        "dom.battery.enabled" = false; # Désactive l'API Battery (+confidentialité)
        "media.navigator.enabled" = false; # Désactive l'accès à la caméra et au micro (+confidentialité)
        "dom.maxHardwareConcurrency" = 4; # Limite le nombre de threads pour réduire l'empreinte digitale (+FingerprintingResist)
        "webgl.enable-debug-renderer-info" = false; # Masque le modèle exact de la carte graphique dans WebGL
        "webgl.disabled" = false; # Désactive WebGL pour éviter les fuites d'informations sur le GPU (désactive map génie)
        "gfx.webrender.all" = true; # Accélération matérielle et rendu GPU sous Wayland
        "media.hardware-video-decoding.enabled" = true;
        "browser.startup.page" = 3; # Reouvrir automatiquement la derniere session (onglets ouverts)
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      }; # Desactivation taille minimale des onglets pour plus de fluidité et d'espace sur la barre d'onglets
      userChrome = ''
        #tabbrowser-tabs .tabbrowser-tab { 
          min-width: 0px !important;
        }
      '';
    };
  };

  # Active la gestion de Home Manager par lui-même
  programs.home-manager.enable = true;

  # Version d'origine (ne pas changer cette valeur après installation)
  home.stateVersion = "24.05";
}