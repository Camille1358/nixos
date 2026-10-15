{ pkgs, ... }:

let
  mathsPackages = import ./py-maths.nix { inherit pkgs; };
in
{
  # (Les outils Python de l'IA ne passent plus par ici : voir IA/paquets.nix.)
  home.packages = [
    (pkgs.python3.withPackages (ps: mathsPackages ps))
  ];
}
