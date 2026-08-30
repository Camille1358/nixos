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
}