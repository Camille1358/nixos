# Applications ajoutées à la demande (partie utilisateur, home-manager).
#   Handy     dictée vocale hors ligne : tu parles, le texte s'écrit à ta place
#   disktree  carte de ce qui remplit le disque
#   Koharu    traduction de mangas par IA locale
{ config, pkgs, pkgs-unstable, lib, ... }:

let
  # ===========================================================================
  # RÉGLAGES
  # ===========================================================================

  # Touche de dictée : MAINTENIR pour parler, relâcher pour que le texte s'écrive.
  # C'est la touche Ctrl de DROITE. Celle de gauche sert à tous les raccourcis
  # (Ctrl+C, Ctrl+V...) : s'en servir ici lancerait une dictée à chaque copier-coller.
  # Autres noms possibles : "Control_L" (Ctrl gauche), "F9", "Menu"...
  toucheDictee = "Control_R";

  # ===========================================================================

  # Handy écrit le texte grâce à wtype (frappe simulée sous Wayland) et au presse-papiers.
  # Il vérifie la présence de wtype avec la commande "which" : sans elle (cas d'un lancement
  # par systemd, dans startup.nix), il croit wtype absent et tape "à l'ancienne" (X11), ce
  # qui n'écrit dans aucune fenêtre Wayland.
  # On les lui fournit directement, pour qu'il les trouve quel que soit son lanceur.
  handy = pkgs.symlinkJoin {
    name = "handy-${pkgs-unstable.handy.version}";
    paths = [ pkgs-unstable.handy ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/handy \
        --prefix PATH : ${lib.makeBinPath [ pkgs.wtype pkgs.wl-clipboard pkgs.which ]} \
        --set-default GDK_BACKEND wayland
    '';
  };

  # Koharu n'a pas de paquet Nix. On prend son paquet officiel (.deb, version et empreinte
  # figées), on en extrait les fichiers, et on le lance dans une "bulle" qui lui présente
  # les bibliothèques là où une distribution classique les range. C'est une application
  # basée sur Chromium, d'où la longue liste.
  # Monter de version : changer le numéro, mettre une empreinte bidon, lancer nrs,
  # recopier l'empreinte que Nix affiche.
  koharuVersion = "0.83.5";
  koharuFichiers = pkgs.stdenv.mkDerivation {
    pname = "koharu-fichiers";
    version = koharuVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/koharu-rs/koharu/releases/download/${koharuVersion}/koharu_${koharuVersion}_amd64.deb";
      sha256 = "1hj4lkqbwvf0r7d97r47d04pqa68dm2vdm69d0aa7sjck5ciw5g4";
    };
    nativeBuildInputs = [ pkgs.dpkg ];
    # (extraction sans les droits spéciaux du fichier chrome-sandbox, interdits dans le magasin Nix)
    unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-permissions --no-same-owner";
    installPhase = "mkdir -p $out && cp -r usr/* $out/ && chmod -R u+w,a-s $out";
    dontFixup = true;
  };
  koharu = pkgs.buildFHSEnv {
    name = "koharu";
    targetPkgs = p: with p; [
      glib nss nspr atk at-spi2-atk at-spi2-core cups dbus expat libdrm gtk3 gtk4 graphene pango cairo
      gdk-pixbuf libxkbcommon alsa-lib systemd libgbm mesa libGL libglvnd vulkan-loader wayland
      fontconfig freetype openssl zlib stdenv.cc.cc.lib libnotify
      libx11 libxcomposite libxdamage libxext libxfixes libxrandr libxcb libxcursor libxi
      libxrender libxtst libxscrnsaver
    ];
    # Indique à son moteur d'affichage (Chromium) où trouver les pilotes graphiques du système.
    profile = ''
      export XDG_DATA_DIRS=/run/opengl-driver/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
      export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
    '';
    runScript = "${koharuFichiers}/share/koharu/koharu";
  };

  # Témoin d'enregistrement. Celui de Handy ne s'affiche pas sous Hyprland (constaté :
  # aucune fenêtre n'est créée pendant l'enregistrement, avec la version 0.9.6 de nixpkgs).
  # On affiche donc le nôtre : une pastille en bas de l'écran tant que la touche est tenue.
  dictee = pkgs.writeShellScript "dictee" ''
    pastille() { # $1 = durée en ms (0 = jusqu'à nouvel ordre), $2 = texte
      ${pkgs.libnotify}/bin/notify-send -a dictee -t "$1" \
        -h string:x-canonical-private-synchronous:dictee "$2"
    }
    case "$1" in
      appui)
        pastille 0 "●  Enregistrement…"
        ${handy}/bin/handy --toggle-transcription
        ;;
      relache)
        ${handy}/bin/handy --toggle-transcription
        pastille 1500 "Transcription…"
        ;;
      annuler)
        ${handy}/bin/handy --cancel
        pastille 800 "Dictée annulée"
        ;;
    esac
  '';
in
{
  home.packages = [
    handy
    pkgs-unstable.disktree # lancer : disktree   (ou disktree /storage pour un autre dossier)
    koharu
  ];

  # Koharu dans le lanceur d'applications (Super+Espace)
  xdg.desktopEntries.koharu = {
    name = "Koharu";
    comment = "Traduction de mangas par IA locale";
    exec = "${koharu}/bin/koharu";
    categories = [ "Graphics" ];
  };

  # Dictée : raccourcis ajoutés à la configuration Lua de Hyprland (voir desktop-home.nix).
  wayland.windowManager.hyprland.extraConfig = ''
    -- Handy (dictée) : appui = début de l'enregistrement, relâchement = le texte s'écrit.
    hl.bind("${toucheDictee}", hl.dsp.exec_cmd("${dictee} appui"))
    -- "CTRL + " : au moment du relâchement, la touche Ctrl compte encore comme enfoncée.
    -- (même réglage que dans l'ancien format, où la dictée fonctionnait)
    hl.bind("CTRL + ${toucheDictee}", hl.dsp.exec_cmd("${dictee} relache"), { release = true })
    -- Secours : si la dictée reste bloquée, Super+Échap annule l'opération en cours.
    hl.bind("SUPER + Escape", hl.dsp.exec_cmd("${dictee} annuler"))
  '';


  # ---------------------------------------------------------------------------
  # Raccourcis Discord utilisables depuis n'importe quelle application
  # ---------------------------------------------------------------------------
  # Sous Wayland, Discord ne reçoit les touches que quand sa fenêtre est au premier plan.
  # Hyprland lui transmet donc lui-même les raccourcis listés ici, où que tu sois. La touche
  # garde aussi son effet normal dans l'application active.
  # Ajouter un raccourci : une ligne vers_discord("touche", "modificateurs"), avec le MÊME
  # raccourci que dans Discord (Paramètres > Raccourcis clavier). Modificateurs possibles :
  # "", "CTRL", "SHIFT", "ALT", "CTRL SHIFT"... Noms des touches : F7, M, 1, Left...
  # (déclaré à part : la dictée, plus haut, définit déjà la même option dans ce fichier)
  imports = [{
    wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
    local function vers_discord(touche, mods)
      local combinaison = (mods ~= "" and (mods:gsub(" ", " + ") .. " + ") or "") .. touche
      hl.bind(combinaison, function()
        local active = hl.get_active_window()
        if active and active.class == "discord" then return end -- Discord la reçoit déjà
        hl.dispatch(hl.dsp.send_shortcut({ window = "class:^(discord)$", mods = mods, key = touche }))
      end, { non_consuming = true })
    end

    vers_discord("F7", "") -- couper / rétablir le micro (TOGGLE_MUTE dans Discord)
    '';
  }];
  # Pastille de dictée : en haut à droite, arrondie comme les modules de la barre.
  services.mako.settings."app-name=dictee" = {
    width = 230;
    border-radius = 22;
    border-color = "#ff3860";
    text-alignment = "center";
    font = "JetBrainsMono Nerd Font Bold 11";
    padding = "10,16";
    default-timeout = 0;
  };
}
