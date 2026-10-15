# L'ASSEMBLAGE : la machine "host" = toutes les fonctionnalités du dossier modules/.
#
# Organisation "dendritique" (flake-parts + import-tree) :
#   - chaque fichier de modules/ décrit UNE fonctionnalité (bureau, jeux, ia...) ;
#   - il y déclare sa partie système (flake.modules.nixos.<nom>) et, s'il en a une,
#     sa partie utilisateur (flake.modules.homeManager.<nom>), côte à côte ;
#   - import-tree charge automatiquement tous les fichiers de modules/ : il n'y a
#     plus de liste d'imports à tenir à jour.
# Ajouter une fonctionnalité = créer un fichier dans modules/.
# En retirer une = supprimer son fichier (ou le renommer avec "_" devant : _jeux.nix
# est ignoré par import-tree).
{ inputs, config, ... }:

let
  system = "x86_64-linux";
  local = import ../local.nix;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;
  };

  # Arguments disponibles dans tous les fichiers (système et home-manager).
  args = {
    inherit pkgs-unstable inputs;
    inherit (inputs) spicetify-nix;
  };
in
{
  # Fournit l'option flake.modules.<classe>.<nom> utilisée par les autres fichiers.
  imports = [ inputs.flake-parts.flakeModules.modules ];

  systems = [ system ];

  # "host" = ton networking.hostName
  flake.nixosConfigurations.host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = args;

    modules =
      # Toutes les parties système déclarées dans modules/
      builtins.attrValues config.flake.modules.nixos
      ++ [
        inputs.home-manager.nixosModules.home-manager
        {
          home-manager.extraSpecialArgs = args;
          # Toutes les parties utilisateur déclarées dans modules/
          home-manager.users.${local.sysName}.imports = builtins.attrValues config.flake.modules.homeManager;
        }
      ];
  };
}
