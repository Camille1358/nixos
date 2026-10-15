# Socle de la machine : démarrage, réseau, son, utilisateur, paquets de base.
{
  flake.modules.nixos.systeme = ../configuration.nix;
  flake.modules.homeManager.systeme = ../home.nix;
}
