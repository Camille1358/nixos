# Pile IA : services (système) ; agents, MCP, skills (utilisateur). Réglages : IA/parametres.nix
{
  flake.modules.nixos.ia = ../IA;
  flake.modules.homeManager.ia = ../IA/home.nix;
}
