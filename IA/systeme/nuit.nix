# NIVEAU 4 (4.5 à 4.7) : boucle de nuit — un agent traite la file de tâches pendant que tu dors.
#
# Principe (flowchart 4.5) : 1 tâche = 1 session neuve de Goose.
#   pour chaque projet de parametres.nix :
#     tant que "bd ready" renvoie une tâche débloquée :
#       créer une branche Git "nuit/<tâche>"
#       Goose réalise la tâche
#       4.6 barrières : tests du projet + relecture Open Code Review (ocr)
#       tests réussis -> commit + tâche fermée ; sinon -> branche laissée telle quelle
#
# Rien n'est jamais poussé ni fusionné : le matin, tu relis les branches "nuit/...".
# Suivre : journalctl -u ia-nuit      Lancer tout de suite : sudo systemctl start ia-nuit
#
# [?] Non testé de bout en bout : il faut un projet avec une file Beads et les modèles téléchargés.
{ config, pkgs, lib, ia, iaPaquets, iaCompte, ... }:

let
  local = import ../../local.nix;
  maison = "/home/${local.sysName}";

  boucle = pkgs.writeShellScript "ia-nuit" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.goose-cli pkgs.beads iaPaquets.ocr iaPaquets.engram pkgs.git pkgs.jq pkgs.coreutils pkgs.bash pkgs.gnugrep pkgs.gnused pkgs.findutils ]}:/etc/profiles/per-user/${local.sysName}/bin:/run/current-system/sw/bin
    journal="${ia.dossier}/agents/nuit"
    mkdir -p "$journal"

    for projet in ${lib.escapeShellArgs ia.nuit.projets}; do
      cd "$projet" || continue
      echo "=== Projet : $projet"
      depart=$(git rev-parse --abbrev-ref HEAD)

      for n in $(seq 1 ${toString ia.nuit.tachesMax}); do
        tache=$(bd ready --json 2>/dev/null | jq -r '.[0].id // empty')
        [ -n "$tache" ] || { echo "Plus de tâche débloquée."; break; }
        echo "--- Tâche $tache ($n/${toString ia.nuit.tachesMax})"

        git switch --quiet "$depart" && git switch --quiet --create "nuit/$tache" || break
        bd update "$tache" --status in_progress >/dev/null 2>&1

        # 1 tâche = 1 session neuve
        goose run --no-session --text "Tu travailles seul, de nuit, sans personne pour te répondre. \
    Lis la tâche Beads avec 'bd show $tache' et réalise-la entièrement dans ce dépôt. \
    N'installe rien sur le système, ne pousse rien, ne change pas de branche. \
    Quand c'est fini, résume ce que tu as fait en quelques lignes." \
          > "$journal/$tache.log" 2>&1

        ${if ia.nuit.tests == "" then "tests_ok=1" else ''
        if ( ${ia.nuit.tests} ) >> "$journal/$tache.log" 2>&1; then tests_ok=1; else tests_ok=0; fi
        ''}

        # Relecture automatique : indicative, son rapport est rangé à côté du journal
        ocr review > "$journal/$tache.relecture.txt" 2>&1 || true

        if [ "$tests_ok" = 1 ] && [ -n "$(git status --porcelain)" ]; then
          git add -A
          git commit --quiet -m "nuit: $tache" -m "Réalisé par la boucle de nuit. Journal : $journal/$tache.log"
          bd close "$tache" --reason "Réalisé de nuit, branche nuit/$tache" >/dev/null 2>&1
          echo "Terminée : branche nuit/$tache"
        else
          bd update "$tache" --status blocked >/dev/null 2>&1
          echo "Non validée (tests en échec ou aucun changement) : voir $journal/$tache.log"
        fi
      done

      git switch --quiet "$depart"
    done
  '';
in
lib.mkIf (ia.actif.boucleDeNuit && ia.nuit.projets != [ ]) {
  systemd.services.ia-nuit = {
    description = "IA 4.5 : boucle de nuit";
    after = [ "llama-swap.service" "omniroute.service" "ia-dossiers.service" ];
    requires = [ "ia-dossiers.service" ];

    environment = {
      HOME = maison;
      # Mêmes branchements que dans ton terminal (voir IA/home.nix)
      GOOSE_PROVIDER = "openai";
      GOOSE_MODEL = ia.modeleDeNuit; # le combo "nuit" si la porte est OmniRoute
      OPENAI_HOST = lib.removeSuffix "/v1" ia.porteUrl;
      GOOSE_DISABLE_KEYRING = "1";
      GOOSE_MODE = "auto"; # l'agent agit sans demander : acceptable uniquement grâce à la cloche ci-dessous
      DO_NOT_TRACK = "1";
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = boucle;
      EnvironmentFile = "-${ia.cleFichier}"; # fournit OPENAI_API_KEY
      User = local.sysName;
      Slice = "ia.slice";
      MemoryMax = ia.memoireMax.nuit;
      RuntimeMaxSec = ia.nuit.dureeMax;
      Nice = 10;

      # 4.7 Isolation légère, sans Docker : la "cloche" systemd.
      # Système en lecture seule ; écriture limitée aux projets déclarés et aux données de l'agent.
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = ia.nuit.projets ++ [ "${ia.dossier}/agents" ]; # mémoire et journaux des agents
      PrivateTmp = true;
      # Pas d'élévation de privilèges (sudo inutilisable).
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      CapabilityBoundingSet = "";
      # Réseau limité à cette machine : l'agent atteint la porte locale, pas Internet.
      # (Si la porte est OmniRoute, c'est OmniRoute qui sort vers le cloud, pas l'agent.)
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
    };
  };

  # 7.5 Planification : une minuterie systemd. "Persistent" rattrape une nuit manquée
  # (ordinateur éteint) au démarrage suivant.
  systemd.timers.ia-nuit = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = ia.nuit.heure;
      Persistent = true;
    };
  };
}
