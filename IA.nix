{ config, pkgs, ... }:

let
  local = import ./local.nix;
in

{
  # Service de base de données vectorielle Qdrant (Rust)
  services.qdrant.enable = true;

  # Service de cache Redis local pour LiteLLM Proxy
  services.redis.servers.llm-cache = {
    enable = true;
    port = 6379;
  };

  # Service d'automatisation n8n
  services.n8n.enable = true;

  # =========================================================================
  # NIVEAU 0 : ACCÉLÉRATION MATÉRIELLE & RUNTIME BAS NIVEAU (AMD ROCm)
  # =========================================================================

  # 0.1 Pilotage Matériel & Drivers ROCm / HIP
  boot.initrd.kernelModules = [ "amdgpu" ];

  # Activation de l'accélération graphique et du driver OpenCL / HIP pour AMD
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      rocmPackages.clr.icd # Moteur ICD HIP/OpenCL pour GPU AMD
    ];
  };

  hardware.amdgpu.opencl.enable = true;

  # Variables d'environnement pour garantir que ROCm détecte le GPU
  environment.variables = {
    # Force la version ROCm pour les cartes grand public Radeon
    HSA_OVERRIDE_GFX_VERSION = "10.3.0"; # Mettre "10.3.0" pour RX 6000, "11.0.0" pour RX 7000
    ROC_ENABLE_PRE_VEGA = "0";
  };

  # Lien symbolique /opt/rocm requis par certaines dépendances HIP/ROCm
  systemd.tmpfiles.rules = [
    "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}"
  ];

  # =========================================================================
  # NIVEAU 1 : INFÉRENCE LOCALE, SERVEUR & TÉLÉCHARGEMENT DÉCLARATIF DES MODÈLES
  # =========================================================================

  # 1.1 Backend Local Ollama (Service natif NixOS)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm; # Remplace acceleration = "rocm"

    # Permet de passer la variable d'environnement directement au service Ollama
    environmentVariables = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0"; # Mettre "10.3.0" si tu as une RX 6000
    };

    # Ouverture de l'interface HTTP standard
    host = "127.0.0.1";
    port = 11434;

    # 1.3 Téléchargement Déclaratif Automatique des Modèles
    loadModels = [
      "qwen2.5-coder:14b"
      "deepseek-r1:14b"
    ];
  };

  # 1.4 Support Fine-Tuning (Axolotl) via Docker avec Pass-Through GPU ROCm
  virtualisation.docker = {
    enable = true;
    # Permet à votre utilisateur d'exécuter des conteneurs sans `sudo`
    extraOptions = "--add-runtime rocm=/usr/bin/docker-containerd-runtime-current";
  };

  # Ajout de votre utilisateur aux groupes GPU et Docker
  users.users.${local.sysName}.extraGroups = [ "video" "render" "docker" ];
}