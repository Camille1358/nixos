# Applications ajoutées à la demande (partie utilisateur, home-manager).
#   Handy     dictée vocale hors ligne : tu parles, le texte s'écrit à ta place
#   disktree  carte de ce qui remplit le disque
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
  ];

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


  # (Raccourcis Discord utilisables depuis n'importe quelle application : réglage
  # "raccourcisDiscord" en haut de desktop-home.nix.)
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
