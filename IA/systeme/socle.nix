# NIVEAU 0 : socle commun à tous les services IA.
{ config, pkgs, lib, ia, iaCompte, ... }:

let
  local = import ../../local.nix;
in
{
  # 0.1 Pilotes : amdgpu, Mesa RADV et ROCm sont déjà déclarés dans games_drivers.nix.
  # On ajoute seulement ton utilisateur aux groupes qui donnent accès à la carte graphique.
  # Le groupe "ia" te laisse parcourir le dossier central sans sudo.
  users.users.${local.sysName}.extraGroups = [ "video" "render" "ia" ];

  # ---------------------------------------------------------------------------
  # Dossier central (parametres.nix : dossier) — créé avant tout service IA
  # ---------------------------------------------------------------------------
  # services/, modeles/, cache/ appartiennent au compte technique "ia" ;
  # agents/ et outils/ t'appartiennent (ce sont tes programmes qui y écrivent).
  systemd.services.ia-dossiers = {
    description = "IA : création du dossier central ${ia.dossier}";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = ia.dossier; # attend le disque s'il est monté à part
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      install -d -m 0755 ${ia.dossier}
      install -d -m 0711 ${ia.dossier}/secrets
      install -d -m 0755 -o ia -g ia ${ia.dossier}/modeles ${ia.dossier}/services ${ia.dossier}/cache
      for d in services/omniroute services/qdrant services/open-webui services/cognee services/vane cache/llama-swap; do
        install -d -m 0750 -o ia -g ia ${ia.dossier}/$d
      done
      for d in agents agents/engram agents/goose agents/nuit outils outils/npm outils/uv; do
        install -d -m 0755 -o ${local.sysName} -g users ${ia.dossier}/$d
      done
    '';
  };

  # Compte technique sans mot de passe ni dossier personnel : il possède les fichiers de
  # modèles, pour que le téléchargement ne tourne pas en administrateur.
  users.users.ia = {
    isSystemUser = true;
    group = "ia";
    description = "Services IA";
  };
  users.groups.ia = { };

  # 0.5 Télémétrie coupée, pour tout le système (services et terminal)
  environment.sessionVariables = {
    DO_NOT_TRACK = "1"; # convention respectée par beaucoup d'outils (dont jcode)
    FEYNMAN_TELEMETRY = "off";
    JCODE_NO_TELEMETRY = "1";
    HF_HUB_DISABLE_TELEMETRY = "1";
    NEXT_TELEMETRY_DISABLED = "1";
    ANONYMIZED_TELEMETRY = "False";
  };

  # La porte (parametres.nix), pour tout programme de ta session : la plupart des outils
  # compatibles OpenAI lisent ces variables d'eux-mêmes.
  environment.sessionVariables = {
    OPENAI_BASE_URL = ia.porteUrl;
    OPENAI_API_BASE = ia.porteUrl; # ancien nom, encore lu par certains outils
    QDRANT_URL = ia.url.qdrant;
    SEARXNG_URL = ia.url.searxng;
    GOOSE_DISABLE_KEYRING = "1"; # Goose : pas de trousseau de mots de passe sous Hyprland
  };
  # La clé, elle, est lue dans le dossier des secrets à l'ouverture de chaque terminal.
  environment.interactiveShellInit = ''
    [ -r ${ia.cleFichier} ] && export "$(cat ${ia.cleFichier})"
  '';

  # 0.7 Surveillance GPU : lance "amdgpu_top" dans un terminal pendant un chargement de modèle
  environment.systemPackages = [ pkgs.amdgpu_top ]
    # Outils de diagnostic ROCm, seulement si ce moteur est choisi dans parametres.nix
    ++ lib.optionals (ia.moteurGPU == "rocm") [ pkgs.rocmPackages.rocm-smi pkgs.rocmPackages.rocminfo ];

  # 0.4 Endurance : tous les services IA sont rangés dans une même "tranche" systemd.
  # Si l'ensemble dépasse ce plafond, le noyau freine l'IA avant tes jeux et ton bureau.
  # Voir la consommation en direct : systemd-cgtop /ia.slice
  systemd.slices.ia = {
    description = "Services IA (dossier /etc/nixos/IA)";
    sliceConfig = {
      MemoryHigh = "28G";
      CPUWeight = 50; # moitié moins prioritaire que le reste quand le processeur est saturé
    };
  };

  # 0.3 Secrets : générés tout seuls au premier démarrage, jamais écrits dans /etc/nixos
  # ni dans le magasin Nix (qui est lisible par tout le monde).
  # (La flowchart prévoyait sops-nix : il impose de chiffrer un fichier à la main avec une
  #  commande. Comme ces secrets sont purement locaux, les générer sur place revient au même
  #  sans aucune manipulation.)
  systemd.services.ia-secrets = {
    description = "IA : génération des secrets locaux (une seule fois)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      cd ${ia.dossier}/secrets

      # Passerelle OmniRoute : clés de chiffrement + mot de passe du tableau de bord
      if [ ! -s omniroute.env ]; then
        mdp=$(openssl rand -base64 18)
        {
          echo "JWT_SECRET=$(openssl rand -base64 48)"
          echo "API_KEY_SECRET=$(openssl rand -hex 32)"
          echo "INITIAL_PASSWORD=$mdp"
        } > omniroute.env
        echo "$mdp" > omniroute-mot-de-passe.txt
      fi
      # Tu peux lire ce mot de passe : cat ${ia.dossier}/secrets/omniroute-mot-de-passe.txt
      chown ${local.sysName} omniroute-mot-de-passe.txt
      chmod 0400 omniroute-mot-de-passe.txt

      [ -s searxng.env ] || echo "SEARXNG_SECRET=$(openssl rand -hex 32)" > searxng.env
      [ -s open-webui.env ] || echo "WEBUI_SECRET_KEY=$(openssl rand -hex 32)" > open-webui.env

      # Clé donnée aux outils quand la porte est le moteur local (il n'en exige aucune).
      # Celle d'OmniRoute (cle-omniroute.env) est créée par le service omniroute-init.
      echo "OPENAI_API_KEY=${ia.cleLocale}" > cle-locale.env
      chown root:ia cle-locale.env
      chmod 0440 cle-locale.env
    '';
  };

  # 0.3 Accès distant (option) : après activation, une seule fois : sudo tailscale up
  services.tailscale.enable = ia.actif.tailscale;
}
