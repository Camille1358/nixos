{ config, pkgs, ... }:

let
  # "path:" = Nix lit /etc/nixos comme un simple dossier, tel qu'il est sur le disque.
  # Sans ce mot, il passerait par git et ne verrait QUE les fichiers suivis par git :
  #   - local.nix (volontairement dans .gitignore) serait introuvable -> erreur ;
  #   - il afficherait "Git tree is dirty" à chaque modification non commitée.
  # Avec "path:", git et NixOS sont indépendants : tu commites quand tu veux, ce que tu veux.
  flake = "path:/etc/nixos#host";
in
{
  programs.bash = {
    shellAliases = {
      # Appliquer la configuration
      nrs = "sudo nixos-rebuild switch --flake ${flake}";
      # Mettre à jour toutes les sources (nixpkgs, home-manager...) puis appliquer
      nrsu = "sudo nix flake update --flake path:/etc/nixos && sudo nixos-rebuild switch --flake ${flake}";
    };
  };
}