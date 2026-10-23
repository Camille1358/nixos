# Deadlock : suivi de progression sur deadlock-api.com (historique complet des parties,
# rang, héros, coéquipiers). Un petit service tourne en arrière-plan : il lit le cache de
# Steam et envoie l'identifiant de chaque partie jouée à deadlock-api.com. Ton profil reste
# débloqué tant qu'il a envoyé au moins une de tes parties dans les 14 derniers jours.
# Il n'envoie que les numéros des parties et ton identifiant Steam public (rien d'autre).
# Profil : https://deadlock-api.com (page du tracker, une fois une partie vérifiée).
# Fenêtre d'état : deadlock-api-ingest --gui
{ inputs, ... }:

let
  local = import ../local.nix;

  # ===========================================================================
  # RÉGLAGE
  # ===========================================================================

  # Lire aussi la mémoire du jeu pendant qu'il tourne, pour retrouver les parties que Steam
  # n'a pas téléchargées. Contrepartie : le service reçoit le droit de lire la mémoire de
  # N'IMPORTE QUEL programme (il ne s'en sert que pour Deadlock, en lecture seule).
  # false = il ne lit que le cache de Steam, ce qui suffit à débloquer ton profil.
  lireMemoireDuJeu = false;

  # ===========================================================================
in
{
  flake.modules.nixos.deadlock-suivi = { config, ... }: let
    programme = "${config.services.deadlock-api-ingest.package}/bin/deadlock-api-ingest";
  in {
    imports = [ inputs.deadlock-api-ingest.nixosModules.default ];

    services.deadlock-api-ingest = {
      enable = true;
      user = local.sysName; # celui qui a Steam
      group = "users";
      readGameMemory = lireMemoireDuJeu;
    };

    # Le service doit pouvoir écrire dans ce dossier ; s'il n'existe pas, il refuse de démarrer.
    systemd.tmpfiles.rules = [
      "d /home/${local.sysName}/.local/share/deadlock-api-ingest 0750 ${local.sysName} users -"
    ];

    # Le service surveille le cache de Steam, mais le jeu n'y met une partie que si tu ouvres
    # son détail (historique, replay) : tes parties jouées n'y arrivaient jamais. Toutes les
    # 6 heures (et 15 min après le démarrage), on demande donc ton historique directement à
    # Steam (avec ta session Steam enregistrée) et on l'envoie. Rien ne se passe si Deadlock
    # est ouvert à ce moment-là (Steam ne répond pas) : ce sera au passage suivant.
    systemd.services.deadlock-mes-parties = {
      description = "Deadlock : envoie l'historique de tes parties à deadlock-api.com";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = local.sysName;
        Group = "users";
        ExecStart = "${programme} --own-matches";
        SuccessExitStatus = "0 1"; # 1 = Deadlock ouvert ou Steam indisponible : réessayé plus tard
      };
    };
    systemd.timers.deadlock-mes-parties = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "6h";
      };
    };

    # OpenSnitch : ce programme (cette version précise) peut se connecter à Steam et à
    # deadlock-api.com sans te le demander. Sans cette règle, Steam lui était refusé.
    services.opensnitch.rules.deadlock-api-ingest = {
      name = "000-deadlock-api-ingest";
      enabled = true;
      action = "allow";
      duration = "always";
      precedence = true; # passe avant une ancienne règle qui le bloquerait
      operator = {
        type = "simple";
        operand = "process.path";
        data = "${config.services.deadlock-api-ingest.package}/bin/.deadlock-api-ingest-wrapped";
      };
    };
  };
}
