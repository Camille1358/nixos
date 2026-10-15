# Désactivé (le "_" devant le nom fait ignorer ce fichier). Pour l'activer : renommer en wireguard.nix
{
  flake.modules.nixos.wireguard = ../wireguard/wireguard.nix;
}
