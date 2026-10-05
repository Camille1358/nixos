{ config, pkgs, ... }:

let
  key = import .wireguard/key/key.nix;
in

{
  networking.wg-quick.interfaces.wg0.autostart = false; # démare au start du pc
  environment.systemPackages = [ pkgs.wireguard-tools ]; # on utilise Wireguard qui est un vpn bien et léger
  services.resolved.enable = true; # Activer systemd-resolved pour que WireGuard puisse appliquer le DNS
  networking.firewall.checkReversePath = "loose"; # INDISPENSABLE pour WireGuard sur NixOS (évite que le firewall bloque le tunnel)

  networking.wg-quick.interfaces = {
    wg0 = { # on conf un tunel "wg0" ( nom standard )
      address = [ "10.2.0.2/32" ]; # mon ip dans le reseau VPN
      dns     = ["10.2.0.1"];  # IP du serveur DNS ( ici mon VPS ) en véritté j'ai pas vraiment de serveur DNS mais c'est récomander de metre la ligne quand meme 
      postUp = ''
        resolvectl dns wg0 10.0.0.1 
      ''
        #resolvectl domain wg0 ~intra.evillesseche.fr ~intra.n-e-v-a.fr
      ; # les deux resolve son la pour indique que mes nom de domain XXXXX.intra.NOM_DE_DOMANDE.fr son a routé sur le VPN ( sinon y trouve pas )
      privateKeyFile = "/etc/nixos/wireguard/key/private.key"; # chemin de la clé privé de mon PC
      peers = [
        {
          publicKey  = "${key.key.TP-Public}"; # Clé plublique du serveur key.key.JP-Public key.key.NO-Public key.key.NL-Public
          allowedIPs = [ "0.0.0.0/0" "::/0" ]; # sous réseaux accécible, redirige IPv4 (0.0.0.0/0) ET IPv6 (::/0) dans le VPN
          endpoint   = "${key.key.TP-IP}:51820"; # IP du serveur ( dans mon cas un VPS ovh
          # endpoint = "IP_V6:51820"; # si j'amain sa marche aussi avec l'ipV6
          persistentKeepalive = 25; # params classique pour le confort
        }
      ];
    };
  };
}