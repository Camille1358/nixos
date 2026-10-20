{ config, pkgs, ... }:

let
  # "path:" = Nix lit /etc/nixos comme un simple dossier, tel qu'il est sur le disque.
  # Sans ce mot, il passerait par git et ne verrait QUE les fichiers suivis par git :
  #   - local.nix (volontairement dans .gitignore) serait introuvable -> erreur ;
  #   - il afficherait "Git tree is dirty" à chaque modification non commitée.
  # Avec "path:", git et NixOS sont indépendants : tu commites quand tu veux, ce que tu veux.
  flake = "path:/etc/nixos#host";

  # "nrs-fenetre" : le même nrs, mais le mot de passe est demandé dans une petite fenêtre
  # (l'agent polkit de Hyprland) au lieu du terminal. Claude s'en sert pour appliquer ses
  # changements à la fin d'une grosse demande : rien ne s'applique sans ton mot de passe.
  appliquer = pkgs.writeShellScript "appliquer-config-nixos" ''
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin
    exec nixos-rebuild switch --flake ${flake}
  '';
  # Le texte affiché dans la fenêtre du mot de passe
  demande = pkgs.writeTextDir "share/polkit-1/actions/fr.local.nrs.policy" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
      "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <action id="fr.local.nrs">
        <description>Appliquer la configuration NixOS</description>
        <message>Appliquer la configuration NixOS (nrs) : mot de passe demandé</message>
        <defaults>
          <allow_any>no</allow_any>
          <allow_inactive>no</allow_inactive>
          <allow_active>auth_admin</allow_active>
        </defaults>
        <annotate key="org.freedesktop.policykit.exec.path">${appliquer}</annotate>
      </action>
    </policyconfig>
  '';
  nrsFenetre = pkgs.writeShellScriptBin "nrs-fenetre" "exec /run/wrappers/bin/pkexec ${appliquer}";
in
{
  environment.systemPackages = [ nrsFenetre demande ];

  programs.bash = {
    shellAliases = {
      # Appliquer la configuration
      nrs = "sudo nixos-rebuild switch --flake ${flake}";
      # Mettre à jour toutes les sources (nixpkgs, home-manager...) puis appliquer
      nrsu = "sudo nix flake update --flake path:/etc/nixos && sudo nixos-rebuild switch --flake ${flake}";
    };
  };
}
