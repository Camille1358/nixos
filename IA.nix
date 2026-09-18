{ config, pkgs, ... }:

let
  local = import ./local.nix;
in

{
  # =========================================================================
  # PAQUETS SYSTÈME GÉNÉRAUX & OUTILS CLI IA
  # =========================================================================

  # Services applicatifs annexes
  services.redis.servers.llm-cache = {
    enable = true;
    port = 6379;
  };

  # 7.4 Orchestrateur Système
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
      rocmPackages.clr.icd
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
  # NIVEAU 1 : INFÉRENCE LOCALE, MODÈLES SPÉCIALISÉS & FINE-TUNING
  # =========================================================================

  # 1.1 Backend Local Général (Ollama ROCm)
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

  # 1.2 Backend Rust (mistral.rs)
  systemd.services.mistralrs = {
    description = "Moteur d'inférence mistral.rs (Niveau 1.2)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    
    environment = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      HF_HOME = "/var/lib/mistralrs"; # Stockage du cache Hugging Face
    };
    
    serviceConfig = {
      ExecStart = "${pkgs.mistral-rs}/bin/mistralrs-server --port 1234 plain -m Qwen/Qwen2.5-Coder-7B-Instruct";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "mistralrs";
      
      # Autorisations matérielles GPU AMD
      DynamicUser = true;
      PrivateDevices = false;
      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # 1.4 Fine-Tuning Sans-Code (Docker ROCm / Axolotl)
  virtualisation.docker = {
    enable = true;
    extraOptions = "--add-runtime rocm=/usr/bin/docker-containerd-runtime-current";
  };

  # Ajout de l'utilisateur aux groupes GPU et Docker
  users.users.${local.sysName}.extraGroups = [ "video" "render" "docker" ];

  # =========================================================================
  # NIVEAU 2 : MÉMOIRE, BASES VECTORIELLES, EMBEDDINGS & PKM
  # =========================================================================

  # 2.1 Vector DB Principale (Qdrant)
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

  # CONTENEURS DÉCLARATIFS OCI (2.3, 2.4, 3.1)
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # 2.3 Embeddings & Rerank (HuggingFace Text Embeddings Inference - TEI)
      tei-embeddings = {
        image = "ghcr.io/huggingface/text-embeddings-inference:rocm-1.6";
        ports = [ "8080:80" ];
        cmd = [ "--model-id" "BAAI/bge-large-en-v1.5" ];
        extraOptions = [ "--device=/dev/kfd" "--device=/dev/dri" ];
      };

      # 2.4 Mémoire Long Terme (Mem0 Server)
      mem0-service = {
        image = "mem0/mem0:latest";
        ports = [ "8081:8000" ];
        environment = {
          QDRANT_HOST = "http://127.0.0.1:6333";
        };
      };

  # =========================================================================
  # NIVEAU 3 : ROUTAGE HYBRIDE, PASSERELLE DOUBLE-COUCHE & CASCHING SÉMANTIQUE
  # =========================================================================

      # 3.1 Façade Utilisateur (OmniRoute)
      omniroute = {
        image = "omniroute/omniroute:latest";
        ports = [ "3000:3000" ];
        environment = {
          LITELLM_BASE_URL = "http://127.0.0.1:4000";
        };
      };
    };
  };

  # 3.2 Proxy Backend Backend (LiteLLM)
  services.litellm = {
    enable = true;
    host = "127.0.0.1";
    port = 4000;
    settings = {
      model_list = [
        # Routage vers mistral.rs (1.2)
        {
          model_name = "qwen-coder";
          litellm_params = {
            model = "openai/Qwen/Qwen2.5-Coder-7B-Instruct";
            api_base = "http://127.0.0.1:1234/v1";
            api_key = "none";
          };
        }
        # Routage vers Ollama ROCm (1.1)
        {
          model_name = "ollama-general";
          litellm_params = {
            model = "ollama/llama3.2";
            api_base = "http://127.0.0.1:11434";
          };
        }
        # Routage vers TEI Embeddings (2.3)
        {
          model_name = "bge-embeddings";
          litellm_params = {
            model = "openai/BAAI/bge-large-en-v1.5";
            api_base = "http://127.0.0.1:8080/v1";
          };
        }
      ];
    };
  };
}