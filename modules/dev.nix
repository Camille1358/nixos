# Développement : devenv (environnements de projet reproductibles) + direnv.
#
# Usage, dans le dossier d'un projet :
#   devenv init      crée devenv.nix (langages, outils, services du projet)
#   devenv shell     ouvre un terminal avec exactement ces outils
#   devenv up        lance les services déclarés (base de données...)
# Avec direnv, l'environnement se charge tout seul en entrant dans le dossier
# (la première fois, il demande : direnv allow).
#
# Ce fichier est écrit directement au format "dendritique" : la fonctionnalité est
# décrite ici, sans fichier séparé ailleurs.
{
  flake.modules.nixos.dev = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.devenv ];

    # direnv + nix-direnv (garde les environnements en cache : rechargement instantané)
    programs.direnv.enable = true;

    # Cache binaire officiel de devenv : évite de compiler ses composants sur ta machine.
    nix.settings = {
      extra-substituters = [ "https://devenv.cachix.org" ];
      extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
    };
  };
}
