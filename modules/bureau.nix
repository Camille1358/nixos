# Bureau Hyprland : session et services (système) ; barre, thème, raccourcis (utilisateur).
{
  flake.modules.nixos.bureau = ../desktop.nix;
  flake.modules.homeManager.bureau = ../desktop-home.nix;
}
