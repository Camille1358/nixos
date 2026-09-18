{ config, pkgs, ... }:

let
  local = import ./local.nix;
in

{
  # Services applicatifs
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
    HSA_OVERRIDE_GFX_VERSION = "10.3.0"; # Mettre "10.3.0" pour RX 6000, "11.0.0" pour RX 7000
    ROC_ENABLE_PRE_VEGA = "0";
  };

  # Lien symbolique /opt/rocm requis par certaines dépendances HIP/ROCm
  systemd.tmpfiles.rules = [
    "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}"
  ];

  # =========================================================================
  # NIVEAU 1 : INFÉRENCE LOCALE & MOTEURS DE MODÈLES
  # =========================================================================

  # 1.1 Moteur Local Ollama
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    rocmOverrideGfx = "10.3.0";
    host = "127.0.0.1";
    port = 11434;

    # 1.3 Téléchargement Déclaratif Automatique des Modèles
    loadModels = [
      "qwen2.5-coder:14b"
      "deepseek-r1:14b"
    ];
  };

  # 1.2 Moteur d'Inférence Rust (mistral.rs)
  systemd.services.mistralrs = {
    description = "Moteur d'inférence mistral.rs (Niveau 1.2)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    
    environment = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      HF_HOME = "/var/lib/mistralrs"; # Redirige le cache Hugging Face dans le dossier persistant du service
    };
    
    serviceConfig = {
      ExecStart = "${pkgs.mistral-rs}/bin/mistralrs-server --port 1234 plain -m Qwen/Qwen2.5-Coder-7B-Instruct -f plain";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      StateDirectory = "mistralrs"; # Crée /var/lib/mistralrs avec les bonnes permissions
      SupplementaryGroups = [ "video" "render" ]; # Donne l'accès au GPU AMD au service
    };
  };

  # 1.4 Support Fine-Tuning (Axolotl) / Docker ROCm
  virtualisation.docker = {
    enable = true;
    extraOptions = "--add-runtime rocm=/usr/bin/docker-containerd-runtime-current";
  };

  # Ajout de l'utilisateur aux groupes GPU et Docker
  users.users.${local.sysName}.extraGroups = [ "video" "render" "docker" ];

  # =========================================================================
  # NIVEAU 2 : UNIFICATION & PROXY GATEWAY (LiteLLM)
  # =========================================================================

  # 2.1 LiteLLM Gateway (Centralise Ollama + mistral.rs sur le port 4000)
  services.litellm = {
    enable = true;
    host = "127.0.0.1";
    port = 4000;
    settings = {
      model_list = [
        # Routage vers mistral.rs (Port 1234)
        {
          model_name = "qwen-coder";
          litellm_params = {
            model = "openai/Qwen/Qwen2.5-Coder-7B-Instruct";
            api_base = "http://127.0.0.1:1234/v1";
            api_key = "none";
          };
        }
        # Routage vers Ollama ROCm (Port 11434)
        {
          model_name = "ollama-general";
          litellm_params = {
            model = "ollama/llama3.2";
            api_base = "http://127.0.0.1:11434";
          };
        }
      ];
    };
  };

  # =========================================================================
  # NIVEAU 3 : BASE VECTORIELLE & MÉMOIRE CONTEXTUELLE (Qdrant)
  # =========================================================================

  services.qdrant = {
    enable = true;
    settings = {
      service = {
        host = "127.0.0.1";
        http_port = 6333;
        grpc_port = 6334;
      };
      storage = {
        storage_path = "/var/lib/qdrant/storage";
        snapshots_path = "/var/lib/qdrant/snapshots";
      };
      hsnw_index = {
        on_disk = true;
      };
      telemetry_disabled = true;
    };
  };
}