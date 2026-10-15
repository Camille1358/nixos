# Outils pour travailler sur les panneaux hors de Nix (cargo build, cargo test) : nix-shell
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  nativeBuildInputs = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt pkgs.pkg-config ];
  buildInputs = [ pkgs.gtk4 pkgs.gtk4-layer-shell ];
  # Fichiers de compilation hors de /etc/nixos (le flake copie tout ce dossier à chaque nrs)
  shellHook = ''export CARGO_TARGET_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/panneaux-cargo"'';
}
