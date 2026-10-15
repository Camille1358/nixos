# Éclairage RGB : OpenRGB pour toutes les LED de l'ordinateur (clavier ROCCAT, carte mère,
# contrôleur NZXT, RAM...). Détails et réglages : rgb/default.nix
{
  flake.modules.nixos.rgb = ../rgb;
}
