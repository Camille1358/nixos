{ config, pkgs, ... }:

{
  networking.firewall = {
    enable = false; # desactiver car ca posé probleme sur le host de certain service/jeux
    allowedTCPPorts = [ 47984 47989 47990 48010 ];
    allowedUDPPortRanges = [
      { from = 47998; to = 48000; }
      { from = 8000; to = 8010; }
    ];
  };
}