# NIVEAU 3 : passerelle local + cloud — OmniRoute.
#
# Ce que Nix règle ici : l'installation, la version, le port, l'écoute en local
# uniquement, les secrets, le redémarrage automatique, le plafond de mémoire.
# Plus bas : la préconfiguration automatique (moteur local, combos, clé des outils).
# Seule chose que Nix ne peut pas faire : ajouter TES comptes cloud, depuis le tableau de
# bord (7.3), puisque ce sont tes identifiants. Voir IA/LISEZMOI.md.
{ config, pkgs, lib, ia, iaPaquets, iaCompte, ... }:

lib.mkIf ia.actif.omniroute {
  systemd.services.omniroute = {
    description = "IA 3.1 : OmniRoute (passerelle local + cloud)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "ia-secrets.service" ];
    wants = [ "network-online.target" ];
    requires = [ "ia-secrets.service" ];

    environment = {
      HOME = "${ia.dossier}/services/omniroute";
      DATA_DIR = "${ia.dossier}/services/omniroute";
      npm_config_cache = "${ia.dossier}/services/omniroute/.npm";
      npm_config_update_notifier = "false";
      NODE_ENV = "production";

      PORT = toString ia.ports.omniroute;
      # 3.3 Durcissement (CVE-2026-88062) : écoute sur cette machine seulement.
      HOSTNAME = ia.hote;
      OMNIROUTE_SERVER_HOST = ia.hote;
      # Les appels /v1 venant de cette machine n'ont pas besoin de clé : c'est ce qui
      # permet à tous les outils de s'y brancher sans distribuer de secret. Le tableau
      # de bord, lui, exige le mot de passe généré dans ${ia.dossier}/secrets.
      REQUIRE_API_KEY = "false";
      # Autorise llama-swap (adresse locale) comme fournisseur.
      OMNIROUTE_ALLOW_PRIVATE_PROVIDER_URLS = "true";

      DO_NOT_TRACK = "1"; # 0.5
      NEXT_TELEMETRY_DISABLED = "1";
    };

    serviceConfig = {
      # Version figée dans parametres.nix (versions.omniroute) ; téléchargée par npm au
      # premier démarrage puis gardée dans ${ia.dossier}/services/omniroute/.npm.
      ExecStart = "${iaPaquets.omniroute}/bin/omniroute serve";
      EnvironmentFile = "${ia.dossier}/secrets/omniroute.env"; # JWT_SECRET, API_KEY_SECRET, INITIAL_PASSWORD

      Slice = "ia.slice";
      WorkingDirectory = "${ia.dossier}/services/omniroute";
      MemoryMax = ia.memoireMax.omniroute; # 0.4
      Restart = "always";
      RestartSec = 10;
      TimeoutStartSec = "15min"; # premier démarrage : téléchargement

      # Cloisonnement : ce programme lance des processus et parle à Internet.
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    } // iaCompte "services/omniroute";
  };
  # ---------------------------------------------------------------------------
  # 3.2 Préconfiguration automatique : moteur local, combos, clé pour les outils
  # ---------------------------------------------------------------------------
  # Fait une fois, puis ne touche plus à rien de ce qui existe déjà : tu peux donc
  # compléter depuis le tableau de bord (comptes cloud) sans que ce soit écrasé.
  # Chaque étape a été essayée à la main sur une instance jetable d'OmniRoute.
  # Rejouer : sudo systemctl restart omniroute-init      Journal : journalctl -u omniroute-init
  systemd.services.omniroute-init = {
    description = "IA 3.2 : préconfiguration d'OmniRoute (moteur local, combos, clé)";
    wantedBy = [ "multi-user.target" ];
    after = [ "omniroute.service" "ia-dossiers.service" ];
    # "wants" et non "requires" : un redémarrage d'OmniRoute n'interrompt pas la préconfiguration,
    # qui attend simplement que la passerelle réponde.
    wants = [ "omniroute.service" ];
    requires = [ "ia-dossiers.service" ];

    path = [ iaPaquets.omniroute pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ];
    environment = {
      HOME = "${ia.dossier}/services/omniroute";
      DATA_DIR = "${ia.dossier}/services/omniroute";
      npm_config_cache = "${ia.dossier}/services/omniroute/.npm";
      npm_config_update_notifier = "false";
      NODE_ENV = "production";
      OMNIROUTE_BASE_URL = ia.url.omnirouteTableau;
      DO_NOT_TRACK = "1";
    };

    script = ''
      url=${ia.url.omnirouteTableau}

      # Attendre que la passerelle réponde (le tout premier démarrage télécharge OmniRoute)
      for i in $(seq 1 450); do
        curl -fs -m 3 -o /dev/null "$url/api/monitoring/health" && break
        sleep 2
      done

      # 1) Le moteur local (llama-swap) comme fournisseur
      if ! omniroute providers list --json | grep -q '"name": "moteur-local"'; then
        omniroute setup --non-interactive --add-provider \
          --provider openai-compatible --provider-name moteur-local \
          --provider-base-url ${ia.url.llamaSwap} --api-key ${ia.cleLocale} \
          --default-model ${ia.modeles.principal.nom}
      fi

      # 2) Les combos de parametres.nix (ceux qui existent déjà sont laissés tels quels)
      existants=$(omniroute combo list)
      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList (nom: modeles: ''
        echo "$existants" | grep -qw -- ${nom} || omniroute combo create ${nom} --strategy priority --models ${lib.escapeShellArg (lib.concatStringsSep "," modeles)}'') ia.combos)}

      # 3) Une clé d'API pour tes outils (OmniRoute en exige une pour lister les modèles)
      if [ ! -s cle-api ]; then
        temoin=$(mktemp)
        curl -fs -m 15 -c "$temoin" -o /dev/null -H 'Content-Type: application/json' \
          -d "{\"password\":\"$INITIAL_PASSWORD\"}" "$url/api/auth/login"
        curl -fs -m 15 -b "$temoin" -H 'Content-Type: application/json' \
          -d '{"name":"porte-locale"}' "$url/api/keys" | jq -er .key > cle-api.tmp
        mv cle-api.tmp cle-api
        rm -f "$temoin"
      fi
    '';

    serviceConfig = {
      # "exec" : tourne en arrière-plan. nrs n'attend donc pas le téléchargement d'OmniRoute
      # (plusieurs minutes la première fois) pour rendre la main.
      Type = "exec";
      EnvironmentFile = "${ia.dossier}/secrets/omniroute.env"; # INITIAL_PASSWORD
      WorkingDirectory = "${ia.dossier}/services/omniroute";
      Slice = "ia.slice";
      Restart = "on-failure";
      RestartSec = 30;
      TimeoutStartSec = "20min";
      UMask = "0077";
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;

      # Une fois la préconfiguration terminée avec succès : range la clé dans le dossier des
      # secrets, lisible par le groupe "ia" (donc par toi et par les services), puis relance
      # Open WebUI pour qu'il la prenne en compte. Le "+" = cette étape tourne en administrateur.
      ExecStopPost = "+" + pkgs.writeShellScript "ranger-cle-omniroute" ''
        [ "$SERVICE_RESULT" = success ] || exit 0
        [ -s ${ia.dossier}/services/omniroute/cle-api ] || exit 0
        nouvelle=1
        ${pkgs.gnugrep}/bin/grep -qsF "$(${pkgs.coreutils}/bin/cat ${ia.dossier}/services/omniroute/cle-api)" ${ia.dossier}/secrets/cle-omniroute.env && nouvelle=0
        cle=$(${pkgs.coreutils}/bin/cat ${ia.dossier}/services/omniroute/cle-api)
        echo "OPENAI_API_KEY=$cle" > ${ia.dossier}/secrets/cle-omniroute.env
        ${pkgs.coreutils}/bin/chown root:ia ${ia.dossier}/secrets/cle-omniroute.env
        ${pkgs.coreutils}/bin/chmod 0440 ${ia.dossier}/secrets/cle-omniroute.env
        [ "$nouvelle" = 1 ] && ${pkgs.systemd}/bin/systemctl --no-block try-restart open-webui.service
        exit 0
      '';
    } // iaCompte "services/omniroute";
  };
}
