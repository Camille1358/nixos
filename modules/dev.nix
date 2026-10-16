# Développement : devenv (environnements de projet reproductibles) + direnv, et les outils
# Rust pour les deux programmes de ce dépôt (panneaux/, IA/memoire/).
#
# Usage, dans le dossier d'un projet :
#   devenv init      crée devenv.nix (langages, outils, services du projet)
#   devenv shell     ouvre un terminal avec exactement ces outils
#   devenv up        lance les services déclarés (base de données...)
# Avec direnv, l'environnement se charge tout seul en entrant dans le dossier
# (la première fois, il demande : direnv allow).
#
# Rust : rust-analyzer (l'extension de VS Code) analyse le code en direct, et clippy (le
# correcteur officiel de Rust) le vérifie à chaque enregistrement. Réglages de l'éditeur :
# .vscode/settings.json. Relancer VS Code après nrs. Rien ne tourne en dehors de l'éditeur.
#
# Ce fichier est écrit directement au format "dendritique" : la fonctionnalité est
# décrite ici, sans fichier séparé ailleurs.
{
  flake.modules.nixos.dev = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.devenv ];

    # direnv + nix-direnv (garde les environnements en cache : rechargement instantané)
    programs.direnv.enable = true;

    # Cache binaire officiel de devenv : évite de compiler ses composants sur ta machine.
    nix.settings = {
      extra-substituters = [ "https://devenv.cachix.org" ];
      extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
    };
  };

  flake.modules.homeManager.dev = { pkgs, lib, ... }:
    let
      # Bibliothèques C dont les programmes Rust du dépôt ont besoin (panneaux : GTK 4)
      bibliotheques = [ pkgs.gtk4 pkgs.gtk4-layer-shell ];

      # Où pkg-config trouve ces bibliothèques et toutes celles dont elles dépendent
      # (calculé une seule fois, à la construction)
      cheminsPkgConfig = pkgs.runCommand "chemins-pkg-config" {
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = bibliotheques;
      } ''echo -n "$PKG_CONFIG_PATH" > $out'';

      # cargo, avec ce qu'il lui faut autour : le compilateur C (pour les petits programmes de
      # préparation des bibliothèques), pkg-config et GTK. Dans /etc/nixos, ses fichiers de
      # compilation vont dans ~/.cache : sinon chaque nrs les recopierait (des centaines de Mo).
      cargo = pkgs.symlinkJoin {
        name = "cargo-${pkgs.cargo.version}";
        paths = [ pkgs.cargo ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/cargo \
            --prefix PATH : ${lib.makeBinPath [ pkgs.stdenv.cc pkgs.pkg-config ]} \
            --prefix PKG_CONFIG_PATH : "$(cat ${cheminsPkgConfig})" \
            --run 'case "$PWD/" in /etc/nixos/*) export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/etc-nixos-rust}";; esac'
        '';
      };
    in
    {
      home.packages = [ cargo pkgs.rustc pkgs.clippy pkgs.rustfmt ];
      # Sources de la bibliothèque standard de Rust, pour rust-analyzer (.vscode/settings.json)
      home.file.".local/share/rust-src".source = pkgs.rustPlatform.rustLibSrc;
    };
}
