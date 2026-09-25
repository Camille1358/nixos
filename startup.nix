{ pkgs, ... }:

{
  systemd.user.services.easyeffects = {
    description = "Service EasyEffects en arrière-plan";
    wantedBy = [ "graphical-session.target" ];
    wants = [ "pipewire.service" ];
    after = [ "pipewire.service" "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
      Restart = "on-failure";
    };
  };

  systemd.user.services.opensnitch-ui = {
    description = "Interface graphique OpenSnitch au démarrage de la session";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.opensnitch-ui}/bin/opensnitch-ui";
      Restart = "on-failure";
    };
  };

  systemd.user.services.auto-update = {
    description = "Mise à jour automatique des paquets critiques au démarrage";
    wantedBy = [ "default.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    script = ''
      # Liste ici les paquets du store nixos-unstable à maintenir à jour
      PACKAGES=(
        "nixpkgs#tor-browser"
        "nixpkgs#mullvad-browser"
      )

      for pkg in "''${PACKAGES[@]}"; do
        ${pkgs.nix}/bin/nix profile install --tarball-ttl 0 "$pkg"
      done
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
  };
}