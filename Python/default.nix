{ pkgs, ... }:

let
  mathsPackages = import ./py-maths.nix { inherit pkgs; };
  iaPackages = import ../IA/py-ia.nix { inherit pkgs; };
in
{
  home.packages = [
    (pkgs.python3.withPackages (
      ps: (mathsPackages ps) ++ (iaPackages ps)
    ))
  ];
}