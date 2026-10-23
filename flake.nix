{
  description = "Config NixOS + home-manager";

  inputs = {
    # Organisation du flake (voir "outputs" tout en bas et le dossier modules/)
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # Système : branche stable (ton system.stateVersion est 26.05)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Remplace tes builtins.fetchTarball ".../nixos-unstable.tar.gz" (version verrouillée dans flake.lock)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Remplace <home-manager/nixos> (la branche doit correspondre à celle de nixpkgs)
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Remplace ton import via flake-compat
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deadlock : envoie tes parties à deadlock-api.com (suivi de progression).
    # Voir modules/deadlock-suivi.nix. Épinglé sur une version : pour monter, change le numéro.
    deadlock-api-ingest.url = "github:deadlock-api/deadlock-api-ingest/v0.4.5";

    # =========================================================================
    # IA (voir le dossier IA/) — chaîne d'approvisionnement, flowchart 0.6
    # Chaque source est épinglée sur une version précise ; son empreinte est
    # enregistrée dans flake.lock. Rien ne se met à jour tout seul : pour monter
    # de version, change le numéro ici puis lance nrsf.
    # "flake = false" = on prend seulement le code, sans exécuter le flake du dépôt.
    # =========================================================================

    # 8.1 Gestionnaire de skills (module Home Manager)
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 8.3 à 8.5 Sources de skills
    skills-pocock = { url = "github:mattpocock/skills/v1.3.1"; flake = false; };
    skills-osmani = { url = "github:addyosmani/agent-skills/0.6.12"; flake = false; };
    skills-archify = { url = "github:tt-a1i/archify/v3.1.0"; flake = false; };
    skills-last30days = { url = "github:mvanhorn/last30days-skill/v3.28.0"; flake = false; };

    # Outils sans paquet nixpkgs, compilés depuis leur code source (IA/paquets.nix)
    engram-src = { url = "github:Gentleman-Programming/engram/v3.4.0"; flake = false; }; # 2.3
    ocr-src = { url = "github:alibaba/open-code-review/v1.13.0"; flake = false; }; # 4.6
    anydoc-src = { url = "github:firecrawl/anydoc/v0.2.4"; flake = false; }; # 6.3
    jcode-src = { url = "github:1jehuang/jcode/v0.95.0"; flake = false; }; # 4.2
    vane-src = { url = "github:ItzCrazyKns/Vane/v1.12.2"; flake = false; }; # 7.2
  };

  # Organisation "dendritique" : flake-parts assemble le flake, et import-tree charge
  # automatiquement tous les fichiers du dossier modules/ (une fonctionnalité par fichier).
  # Le point de départ pour lire la configuration est modules/hote.nix.
  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
