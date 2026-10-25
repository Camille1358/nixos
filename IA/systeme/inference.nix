# NIVEAU 1 : inférence locale — un moteur (llama.cpp), une seule porte (llama-swap).
{ config, pkgs, lib, ia, iaCompte, ... }:

let
  dossier = "${ia.dossier}/modeles";

  # 1.1 Le moteur, selon parametres.nix
  moteur = if ia.moteurGPU == "rocm" then pkgs.llama-cpp-rocm else pkgs.llama-cpp-vulkan;

  # Commande de lancement d'un modèle. llama-swap remplace ''${PORT} par un port libre.
  commande = m: lib.concatStringsSep " " [
    "${moteur}/bin/llama-server"
    "--host 127.0.0.1 --port \${PORT} --no-webui"
    "--model ${dossier}/${m.fichier}"
    "--alias ${m.nom}"
    "--ctx-size ${toString m.contexte}"
    m.options
  ]
  # Ta machine a deux puces graphiques (la RX 6800 XT et celle intégrée au processeur).
  # Sans cette précision, llama.cpp répartit le modèle sur les deux, et la puce intégrée
  # ralentit tout.
  + lib.optionalString (ia.moteurGPU == "vulkan" && lib.hasInfix "-ngl 99" m.options) " --device ${ia.carteVulkan}";

  gros = [ ia.modeles.principal ia.modeles.repli ]; # sur la carte graphique
  petits = [ ia.modeles.embeddings ia.modeles.rerank ]; # sur le processeur
in
lib.mkIf ia.actif.inference {
  # ---------------------------------------------------------------------------
  # 1.2 Chef d'orchestre : llama-swap
  # ---------------------------------------------------------------------------
  # Il expose UNE adresse compatible OpenAI et charge le bon modèle à la demande,
  # d'après le champ "model" de chaque requête.
  services.llama-swap = {
    enable = true;
    listenAddress = ia.hote;
    port = ia.ports.llamaSwap;

    settings = {
      healthCheckTimeout = 600; # un gros modèle peut mettre plusieurs minutes à charger
      logLevel = "info";

      models = lib.listToAttrs (
        map (m: lib.nameValuePair m.nom { cmd = commande m; ttl = ia.dechargementApres; }) gros
        ++ map (m: lib.nameValuePair m.nom {
          cmd = commande m;
          # Indexer un document envoie des dizaines de demandes d'un coup : sans cette
          # marge, llama-swap en refuse au-delà de 10 (constaté avec Open WebUI).
          concurrencyLimit = 200;
        }) petits
      );

      groups = {
        # Un seul gros modèle chargé à la fois : demander l'autre décharge le premier.
        gpu = {
          swap = true;
          exclusive = false;
          members = map (m: m.nom) gros;
        };
        # 1.5 Embeddings et rerank restent chargés en permanence, à côté du LLM.
        cpu = {
          swap = false;
          exclusive = false;
          persistent = true;
          members = map (m: m.nom) petits;
        };
      };
    };
  };

  systemd.services.llama-swap = {
    after = [ "ia-modeles.service" ];
    environment = {
      # Le service n'a pas de dossier personnel : on lui en donne un pour le cache des shaders Vulkan.
      HOME = "${ia.dossier}/cache/llama-swap";
      XDG_CACHE_HOME = "${ia.dossier}/cache/llama-swap";
    } // lib.optionalAttrs (ia.moteurGPU == "vulkan") {
      # Seule la RX 6800 XT est visible du moteur (voir carteVulkanId, parametres.nix)
      MESA_VK_DEVICE_SELECT = ia.carteVulkanId;
      MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE = "1";
    } // lib.optionalAttrs (ia.moteurGPU == "rocm") {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0"; # la RX 6800 XT (gfx1030) vue par ROCm
    };
    serviceConfig = {
      Slice = "ia.slice";
      MemoryMax = ia.memoireMax.llamaSwap; # 0.4
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce 5;
      # Le module NixOS interdit par défaut la mémoire à la fois inscriptible et exécutable ;
      # les pilotes graphiques en ont besoin pour compiler leurs shaders.
      MemoryDenyWriteExecute = lib.mkForce false;
    } // iaCompte "cache/llama-swap";
  };

  # ---------------------------------------------------------------------------
  # 1.3 à 1.5 Téléchargement des modèles (automatique, reprend où il s'était arrêté)
  # ---------------------------------------------------------------------------
  # ~28 Go au total la première fois. Suivre l'avancement : journalctl -fu ia-modeles
  # Tant qu'un modèle n'est pas arrivé, llama-swap répond par une erreur pour ce modèle.
  systemd.services.ia-modeles = {
    description = "IA : téléchargement des modèles GGUF";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.coreutils ];
    serviceConfig = {
      Type = "exec"; # ne bloque pas nrsf pendant le téléchargement
      Slice = "ia.slice";
      Restart = "on-failure";
      RestartSec = 60;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
    } // iaCompte "modeles";
    script = ''
      cd ${dossier}
      telecharger() { # $1 = dépôt Hugging Face, $2 = fichier
        if [ -s "$2" ]; then
          echo "Déjà présent : $2"
          return
        fi
        echo "Téléchargement : $1/$2"
        curl --fail --location --continue-at - --retry 5 --retry-delay 10 \
          --output "$2.partiel" "https://huggingface.co/$1/resolve/main/$2"
        mv "$2.partiel" "$2"
        echo "Terminé : $2"
      }
      ${lib.concatMapStringsSep "\n" (m: "telecharger ${m.depot} ${m.fichier}") (petits ++ [ ia.modeles.repli ia.modeles.principal ])}
    '';
  };
}
