# Éclairage RGB : toutes les LED de l'ordinateur pilotées par OpenRGB.
#
#   Matériel trouvé : clavier ROCCAT Vulcan II Max (USB), carte mère ASUS AURA (USB),
#   contrôleur NZXT RGB & Fan (USB), et la RAM si elle est éclairée (bus SMBus de la carte mère).
#
# Comment ça marche : un service OpenRGB (root) démarre avec la machine et parle au matériel.
# L'application OpenRGB (menu des applications) s'y connecte : couleurs, effets et LUMINOSITÉ
# de chaque appareil se règlent là, et peuvent être enregistrés dans un profil.
# (L'application ne parle jamais directement au matériel : deux programmes qui pilotent les
# mêmes LED en même temps se gênent.)
#
# Correctif du clavier : OpenRGB plantait avec le Vulcan II Max en disposition française.
# Il ne connaît pour ce clavier que la disposition américaine ; en ISO (FR, DE, UK) il lisait
# une disposition vide, écrivait hors de sa mémoire dès qu'on choisissait une couleur, puis
# s'arrêtait (trace du 02/10/2026 : double libération de mémoire dans hid_close). Le patch
# openrgb-vulcan-ii-max-iso.patch lui donne les adresses ISO (celles du Vulcan II, même
# matrice de touches) et garde les 40 LED secondaires du Max (témoins, repose-poignets).
{ pkgs, ... }:

let
  # ===========================================================================
  # RÉGLAGES
  # ===========================================================================
  # Processeur de la carte mère : "amd" ou "intel" (pour la RAM et les LED sur le bus SMBus)
  carteMere = "amd";

  openrgb = pkgs.openrgb.overrideAttrs (ancien: {
    patches = (ancien.patches or [ ]) ++ [ ./openrgb-vulcan-ii-max-iso.patch ];
    # L'application se connecte au service au lieu de piloter elle-même le matériel
    postInstall = (ancien.postInstall or "") + ''
      for f in $out/share/applications/*.desktop; do
        # Seulement la ligne Exec= : TryExec doit rester le seul nom du programme, sinon les
        # lanceurs d'applications (Rofi) croient OpenRGB absent et le cachent.
        sed -i 's/^Exec=openrgb$/Exec=openrgb --client/' "$f"
      done
    '';
  });
in
{
  services.hardware.openrgb = {
    enable = true;
    package = openrgb;
    motherboard = carteMere; # charge le pilote SMBus de la carte mère (i2c-piix4 pour AMD)
  };
  hardware.i2c.enable = true; # accès aux LED de la RAM et de la carte mère par le bus SMBus

  environment.systemPackages = [ openrgb ];
}
