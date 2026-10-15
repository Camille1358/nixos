# IA — partie SYSTÈME (services). Activée par la ligne ./IA dans configuration.nix.
# La partie utilisateur (agents, skills, MCP) est dans IA/home.nix, activée dans home.nix.
#
#   parametres.nix          le tableau de bord : ports, modèles, interrupteurs  <- à modifier
#   paquets.nix             les outils absents de nixpkgs
#   systeme/socle.nix       niveau 0 : secrets, télémétrie, mémoire, surveillance GPU
#   systeme/inference.nix   niveau 1 : llama-swap, llama.cpp, téléchargement des modèles
#   systeme/donnees.nix     niveau 2 : Qdrant, Cognee
#   systeme/passerelle.nix  niveau 3 : OmniRoute
#   systeme/interfaces.nix  niveaux 6-7 : SearXNG, Open WebUI, Vane, n8n
#   systeme/nuit.nix        niveau 4 : boucle de nuit sous cloche
#   home.nix                niveaux 4, 5, 8 : agents, serveurs MCP, skills
#   LISEZMOI.md             adresses, premiers pas, ce qui reste à tester
{ pkgs, lib, inputs, ... }:

let
  ia = import ./parametres.nix;
in
{
  imports = [
    ./systeme/socle.nix
    ./systeme/inference.nix
    ./systeme/donnees.nix
    ./systeme/passerelle.nix
    ./systeme/interfaces.nix
    ./systeme/nuit.nix
  ];

  # Rend "ia" (les paramètres) et "iaPaquets" disponibles dans tous les fichiers ci-dessus.
  _module.args = {
    inherit ia;
    iaPaquets = import ./paquets.nix { inherit pkgs lib inputs; p = ia; };

    # Réglages communs à tous les services IA pour écrire dans le dossier central
    # (parametres.nix : dossier). Usage : serviceConfig = { ... } // iaCompte "services/qdrant";
    # - le service tourne sous le compte technique "ia", qui possède le dossier central ;
    # - le reste du disque lui est interdit en écriture, sauf son propre sous-dossier.
    iaCompte = sous: {
      DynamicUser = lib.mkForce false;
      User = "ia";
      Group = "ia";
      ReadWritePaths = [ "${ia.dossier}/${sous}" ];
    };
  };

  # Tout service IA attend que le dossier central existe (créé par ia-dossiers, socle.nix).
  systemd.services = lib.genAttrs
    (lib.optional ia.actif.inference "llama-swap"
      ++ lib.optional ia.actif.inference "ia-modeles"
      ++ lib.optional ia.actif.qdrant "qdrant"
      ++ lib.optional ia.actif.cognee "cognee"
      ++ lib.optional ia.actif.omniroute "omniroute"
      ++ lib.optionals ia.actif.searxng [ "searx" "searx-init" ]
      ++ lib.optional ia.actif.openWebui "open-webui"
      ++ lib.optional ia.actif.vane "vane"
      ++ [ "ia-secrets" ])
    (_: {
      after = [ "ia-dossiers.service" ];
      requires = [ "ia-dossiers.service" ];
    });
}
