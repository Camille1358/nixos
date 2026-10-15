# MF Algebra : animations d'algèbre avec Manim (https://github.com/TheMathematicFanatic/MF_Algebra).
#
# Une application du lanceur (Super+Espace → "MF Algebra") : un terminal ouvert dans ton
# dossier de travail (~/Documents/MF_Algebra), où la commande "mfa" rend une scène en vidéo
# et la lit. Exemples prêts à l'emploi : exemples.py (copié à la première ouverture).
#
#   mfa                        rend la scène d'exemple Resoudre (exemples.py)
#   mfa fichier.py Scene       rend la scène "Scene" de fichier.py, puis lit la vidéo
#   mfa fichier.py Scene --hd  en haute qualité (plus long)
#
# RIEN ne tourne en arrière-plan : Python ne démarre que pendant le rendu d'une scène, puis
# s'arrête. Python, Manim et LaTeX ne sont même pas dans le PATH de ta session : seulement
# dans le terminal de l'application.
# Désinstaller : renommer modules/mf-algebra.nix en modules/_mf-algebra.nix, puis nrs.
{ config, pkgs, lib, ... }:

let
  # ===========================================================================
  # RÉGLAGES
  # ===========================================================================
  dossier = "${config.home.homeDirectory}/Documents/MF_Algebra"; # ton dossier de travail

  # Versions figées (commits GitHub). Monter de version : changer le commit, mettre une
  # empreinte bidon, lancer nrs, recopier l'empreinte que Nix affiche.
  versions = {
    algebra = { rev = "b43f3d1253cbed8ebed4549c823c3bfa13f0a1c2"; hash = "sha256-hsfZ9jQpuUJaJqoJ1p3WPLz8VRch1G0EnsrlgK704as="; }; # 0.6.2
    tools = { rev = "f01e7dfe4c6302f0697ec7e558753dd648f029e6"; hash = "sha256-dDWU/+MZSbzs7Z0HOj8p2oJLPuniqu/0tBvNgoK49q4="; }; # 1.4.10
  };
  # ===========================================================================

  py = pkgs.python3Packages;

  mf-tools = py.buildPythonPackage {
    pname = "mf-tools";
    version = "1.4.10";
    pyproject = true;
    src = pkgs.fetchFromGitHub { owner = "TheMathematicFanatic"; repo = "MF_Tools"; inherit (versions.tools) rev hash; };
    build-system = [ py.poetry-core ];
    dependencies = [ py.manim py.fonttools ];
    pythonRelaxDeps = [ "fonttools" ]; # demande 4.65, nixpkgs a 4.61 : vérifié, ça fonctionne
    pythonImportsCheck = [ "MF_Tools" ];
  };

  mf-algebra = py.buildPythonPackage {
    pname = "mf-algebra";
    version = "0.6.2";
    pyproject = true;
    src = pkgs.fetchFromGitHub { owner = "TheMathematicFanatic"; repo = "MF_Algebra"; inherit (versions.algebra) rev hash; };
    build-system = [ py.poetry-core ];
    dependencies = [ py.manim mf-tools py.sympy py.tabulate py.dill py.asteval ];
    pythonRelaxDeps = true;
    # Correctif : sous Manim Community, une formule est rangée dans un niveau de plus que sous
    # ManimGL. Les couleurs (auto_color…) indexaient la formule brute → "IndexError". On passe
    # par l'intermédiaire prévu (MobHolder) qui gère les deux versions de Manim.
    postPatch = ''
      substituteInPlace src/MF_Algebra/expressions/expression_core.py \
        --replace-fail "result.add(*[self.mob[g] for g in" "self.mob; result.add(*[self._mob[g] for g in"
    '';
    pythonImportsCheck = [ "MF_Algebra" ];
  };

  python = pkgs.python3.withPackages (_: [ py.manim mf-algebra mf-tools py.sympy ]);

  # LaTeX : les formules sont composées par LaTeX. On reprend le TeX Live complet déjà installé
  # (home.nix) : il contient tout ce que demande Manim, sans seconde installation sur le disque.
  latex = pkgs.texlive.combined.scheme-full;

  # Outils du terminal de l'application, et nulle part ailleurs
  outils = lib.makeBinPath [ python latex pkgs.ffmpeg pkgs.mpv pkgs.coreutils ];

  # mfa : rendre une scène et la lire
  mfa = pkgs.writeShellScriptBin "mfa" ''
    export PATH=${outils}:$PATH
    fichier=''${1:-exemples.py}
    scene=''${2:-Resoudre}
    qualite=-ql # rapide : 480p
    [ "''${3:-}" = "--hd" ] && qualite=-qh # 1080p
    echo "Rendu de la scène $scene ($fichier)…"
    manim render --silent $qualite --media_dir medias "$fichier" "$scene" || exit 1
    video=$(ls -t medias/videos/*/*/"$scene".mp4 2>/dev/null | head -1)
    [ -n "$video" ] && exec mpv --really-quiet "$video"
  '';

  # L'application : un terminal dans le dossier de travail, préparé à la première ouverture
  application = pkgs.writeShellScriptBin "mf-algebra" ''
    mkdir -p "${dossier}"
    [ -e "${dossier}/exemples.py" ] || install -m 644 ${./exemples.py} "${dossier}/exemples.py"
    exec ${pkgs.kitty}/bin/kitty --class mf-algebra --title "MF Algebra" --directory "${dossier}" \
      env PATH=${lib.makeBinPath [ mfa ]}:${outils}:$PATH \
      ${pkgs.bashInteractive}/bin/bash --rcfile ${./accueil.sh}
  '';
in
{
  home.packages = [ application ];

  xdg.desktopEntries.mf-algebra = {
    name = "MF Algebra";
    genericName = "Animations d'algèbre (Manim)";
    comment = "Dossier de travail MF Algebra : écrire et rendre des animations d'algèbre";
    exec = "${application}/bin/mf-algebra";
    icon = "accessories-calculator";
    categories = [ "Education" "Math" ];
  };
}
