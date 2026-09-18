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
    settings = {
      maxmemory = "2gb";
      maxmemory-policy = "allkeys-lru"; # Éviction automatique pour le caching sémantique (Niveau 3.3)
    };
  };

  # =========================================================================
  # NIVEAU 0 : ACCÉLÉRATION MATÉRIELLE & RUNTIME BAS NIVEAU (AMD ROCm)
  # =========================================================================

  # 0.1 Pilotage Matériel & Drivers ROCm / HIP
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelParams = [
    "amdgpu.vm_fragment_size=9"       # Alignement de la taille de page VRAM pour réduire la fragmentation
    "amdgpu.ppfeaturemask=0xffffffff" # Gestion débridée des fréquences/puissances GPU
    "amdgpu.gpu_recovery=1"           # Récupération automatique du GPU sans plantage du système en cas d'OOM
  ];

  # Suppression des plafonds d'allocation mémoire pour le runtime ROCm/HIP
  security.pam.loginLimits = [
    { domain = "*"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "*"; item = "nofile";  type = "-"; value = "1048576"; }
  ];

  # Drivers graphiques et bibliothèques de calcul HIP / ROCm / OpenCL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      rocmPackages.clr.icd
      rocmPackages.rocblas
      rocmPackages.hipblas
      rocmPackages.rocm-smi
    ];
  };

  hardware.amdgpu.opencl.enable = true;

  # Variables d'environnement globales pour le pilotage ROCm / PyTorch
  environment.variables = {
    HSA_OVERRIDE_GFX_VERSION = "10.3.0";          # Spoof RDNA2 pour compatibilité ROCm universelle
    ROC_ENABLE_PRE_VEGA = "0";
    PYTORCH_ROCM_ALLOC_CONF = "max_split_size_mb:512"; # Allocation mémoire granulaire PyTorch
    HIP_VISIBLE_DEVICES = "0";
    GPU_MAX_ALLOC_PERCENT = "100";
    GPU_SINGLE_ALLOC_PERCENT = "100";
    AMD_LOG_LEVEL = "0";                          # Suppression des logs verbeux ROCm
  };

  # Lien symbolique requis pour les runtimes HIP/ROCm natifs
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
    host = "0.0.0.0";
    port = 11434;

    # Injection directe des variables de comportement du serveur d'inférence
    environmentVariables = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      OLLAMA_NUM_PARALLEL = "4";         # Inférence simultanée de 4 requêtes d'agents
      OLLAMA_MAX_LOADED_MODELS = "2";    # Maintient 2 modèles distincts réservés en VRAM
      OLLAMA_KEEP_ALIVE = "24h";         # Aucune décharge VRAM pour zéro latence au démarrage
      OLLAMA_FLASH_ATTENTION = "1";      # Utilisation du Flash Attention pour diviser l'empreinte VRAM
      OLLAMA_ORIGINS = "*";              # Autorise les appels CORS multi-domaines
      OLLAMA_KV_CACHE_TYPE = "q4_0";     # Quantification du KV cache pour quadrupler la fenêtre de contexte
    };

    loadModels = [
      "qwen2.5-coder:14b"
      "deepseek-r1:14b"
      "bge-m3"
    ];
  };

  # 1.2 Backend Rust Rapide (mistral.rs)
  systemd.services.mistralrs = {
    description = "Serveur d'Inférence Rust mistral.rs (Niveau 1.2)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      HSA_ENABLE_SDMA = "0";
      HF_HOME = "/var/lib/mistralrs";
    };

    serviceConfig = {
      ExecStart = "${pkgs.mistral-rs}/bin/mistralrs-server --port 1234 plain -m Qwen/Qwen2.5-Coder-7B-Instruct";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "mistralrs";
      LimitMEMLOCK = "infinity";

      DynamicUser = true;
      PrivateDevices = false;
      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # 1.3 Moteur GGUF/C++ Native (llama.cpp OpenAI API Server)
  systemd.services.llama-cpp-server = {
    description = "Serveur llama.cpp OpenAI Native (Niveau 1.3)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
    };

    path = [ pkgs.curl ];

    serviceConfig = {
      # Téléchargement automatique du modèle GGUF dans /var/lib/llama-cpp s'il est absent
      ExecStartPre = pkgs.writeShellScript "download-gguf" ''
        if [ ! -f /var/lib/llama-cpp/modele.gguf ]; then
          echo "Téléchargement du modèle GGUF Qwen2.5-Coder..."
          ${pkgs.curl}/bin/curl -L "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf" -o /var/lib/llama-cpp/modele.gguf
        fi
      '';
      ExecStart = ''
        ${pkgs.llama-cpp-rocm}/bin/llama-server \
          --host 0.0.0.0 \
          --port 8085 \
          -m /var/lib/llama-cpp/modele.gguf \
          -ngl 99 \
          -c 8192 \
          --cont-batching \
          --embedding \
          --alias qwen-1.5b
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "llama-cpp";
      LimitMEMLOCK = "infinity";

      DynamicUser = true;
      PrivateDevices = false;
      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # 1.4 Virtualisation Docker (ROCm passthrough)
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    daemon.settings = {
      default-ulimits = {
        memlock = { name = "memlock"; soft = -1; hard = -1; };
      };
    };
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
        host = "0.0.0.0";
        http_port = 6333;
        grpc_port = 6334;
        enable_cors = true;
      };
      storage = {
        storage_path = "/var/lib/qdrant/storage";
        snapshots_path = "/var/lib/qdrant/snapshots";
        on_disk_payload = true;
      };
      hsnw_index = {
        on_disk = true;
        m = 16;
        ef_construct = 100;
      };
      telemetry_disabled = true;
    };
  };

# CONTENEURS DÉCLARATIFS OCI (Niveaux 2, 3, 5, 6, 7)
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # 2.3 Embeddings & Rerank (HuggingFace TEI)
    tei-embeddings = {
      image = "ghcr.io/huggingface/text-embeddings-inference:rocm-1.6";
      ports = [ "8080:80" ];
      cmd = [
        "--model-id" "BAAI/bge-large-en-v1.5"
        "--port" "80"
        "--max-concurrent-requests" "512"
        "--max-batch-tokens" "16384"
        "--auto-truncate"
      ];
      extraOptions = [ "--device=/dev/kfd" "--device=/dev/dri" ];
    };

      # 2.4 Service de Mémoire Long Terme (Mem0 Server)
    mem0-service = {
      image = "mem0/mem0:latest";
      ports = [ "8081:8000" ];
      environment = {
        VECTOR_STORE = "qdrant";
        QDRANT_HOST = "http://host.docker.internal:6333";
        LLM_PROVIDER = "ollama";
        OLLAMA_BASE_URL = "http://host.docker.internal:11434";
        OLLAMA_MODEL = "qwen2.5-coder:14b";
        EMBEDDING_PROVIDER = "openai";
        OPENAI_BASE_URL = "http://host.docker.internal:8080/v1";
        OPENAI_API_KEY = "none";
      };
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };

      # 3.1 Façade Utilisateur (OmniRoute) - Port 3000
      omniroute = {
        image = "omniroute/omniroute:latest";
        ports = [ "3000:3000" ];
        environment = {
          LITELLM_BASE_URL = "http://host.docker.internal:4000";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.3 Perplexica (Search IA) - Port réattribué à 3005
      perplexica-app = {
        image = "itshasbulla/perplexica:latest";
        ports = [ "3005:3000" ];
        environment = {
          SEARXNG_API_URL = "http://host.docker.internal:8888";
          OLLAMA_API_URL = "http://host.docker.internal:11434";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.4 GPT Researcher
      gpt-researcher = {
        image = "gptresearcher/gpt-researcher:latest";
        ports = [ "8000:8000" ];
        environment = {
          SEARXNG_BASE_URL = "http://host.docker.internal:8888";
          OPENAI_BASE_URL = "http://host.docker.internal:11434/v1";
          OPENAI_API_KEY = "ollama";
          FAST_LLM_MODEL = "openai/qwen2.5-coder";
          SMART_LLM_MODEL = "openai/qwen2.5-coder";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 5.4 Observabilité LLMOps (Langfuse Server) - Port 3001
      langfuse-server = {
        image = "langfuse/langfuse:2";
        ports = [ "3001:3000" ];
        environment = {
          DATABASE_URL = "postgresql://langfuse@host.docker.internal:5432/langfuse?sslmode=disable";
          NEXTAUTH_URL = "http://localhost:3001";
          NEXTAUTH_SECRET = "secret_de_dev_a_changer_en_prod_123456789";
          SALT = "salt_de_dev_a_changer_123456789";
          TELEMETRY_ENABLED = "false";
          ENCRYPTION_KEY = "0000000000000000000000000000000000000000000000000000000000000000";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 7.2 Workspace RAG Isolé (AnythingLLM) - Port 3002
      anythingllm = {
        image = "mintplexlabs/anythingllm:latest";
        ports = [ "3002:3001" ];
        volumes = [
          "/var/lib/anythingllm:/app/server/storage"
        ];
        environment = {
          STORAGE_DIR = "/app/server/storage";
          DISABLE_TELEMETRY = "true";
        };
      };

      # 7.3 Studio Visuel d'Agents (Dify Web) - Port 3003
      dify-web = {
        image = "langgenius/dify-web:latest";
        ports = [ "3003:3000" ];
        environment = {
          CONSOLE_API_URL = "http://localhost:5001";
          APP_API_URL = "http://localhost:5001";
        };
      };

      # 7.3 Studio Visuel d'Agents (Dify API) - Port 5001
      dify-api = {
        image = "langgenius/dify-api:latest";
        ports = [ "5001:5001" ];
        environment = {
          MODE = "api";
          LOG_LEVEL = "INFO";
        };
      };
    };
  };

  # =========================================================================
  # NIVEAU 3 : ROUTAGE HYBRIDE, PASSERELLE DOUBLE-COUCHE & CASCHING SÉMANTIQUE
  # =========================================================================

  # 3.2 Proxy Backend Backend (LiteLLM)
  services.litellm = {
    enable = true;
    host = "0.0.0.0";
    port = 4000;
    settings = {
      general_settings = {
        master_key = "sk-litellm-local-root-key";
        store_model_in_db = false;
        database_url = "";
      };
      litellm_settings = {
        drop_params = true;
        set_verbose = false;
        request_timeout = 600;
        num_retries = 3;
        cache = true;
        cache_params = {
          type = "redis";
          host = "127.0.0.1";
          port = 6379;
          namespace = "litellm.cache";
          supported_call_types = [ "completion" "embeddings" ];
        };
      };
      model_list = [
        # Routage vers mistral.rs (1.2)
        {
          model_name = "qwen-coder";
          litellm_params = {
            model = "openai/Qwen/Qwen2.5-Coder-7B-Instruct";
            api_base = "http://127.0.0.1:1234/v1";
            api_key = "none";
            timeout = 300;
          };
        }
        # Routage vers Ollama ROCm (1.1)
        {
          model_name = "ollama-general";
          litellm_params = {
            model = "ollama/qwen2.5-coder:14b";
            api_base = "http://127.0.0.1:11434";
            stream = true;
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

  # =========================================================================
  # NIVEAU 5 : PROTOCOLE MCP, FRAMEWORKS D'AGENTS & OBSERVABILITÉ
  # =========================================================================

  # 5.4 Base de données PostgreSQL dédiée à Langfuse
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    settings = {
      listen_addresses = "*";
      max_connections = 100;
      shared_buffers = "512MB";
    };
    ensureDatabases = [ "langfuse" ];
    ensureUsers = [
      {
        name = "langfuse";
        ensureDBOwnership = true;
      }
    ];
    # Authentification locale sans mot de passe pour le conteneur
    authentication = pkgs.lib.mkOverride 10 ''
      local   all             all                                     trust
      host    langfuse        langfuse        172.17.0.0/16           trust
      host    langfuse        langfuse        127.0.0.1/32            trust
    '';
  };

  # =========================================================================
  # NIVEAU 6 : INGESTION WEB HAUTE VITESSE, SEARCH IA & AGENTS CLI
  # =========================================================================

  # 6.3 Recherche Sémantique - Moteur SearXNG (Service Natif NixOS)
  services.searx = {
    enable = true;
    package = pkgs.searxng;
    settings = {
      server = {
        port = 8888;
        bind_address = "0.0.0.0";
        secret_key = "searxng_secret_key_a_changer_en_prod";
      };
      search = {
        safe_search = 0;
        autocomplete = "google";
        formats = [ "html" "json" ];
      };
      engines = [
        { name = "bing"; engine = "bing"; shortcut = "b"; }
        { name = "duckduckgo"; engine = "duckduckgo"; shortcut = "ddg"; }
        { name = "google"; engine = "google"; shortcut = "g"; }
      ];
    };
  };

  # =========================================================================
  # NIVEAU 7 : WORKFLOWS AUTOMATISÉS, ESPACES DE TRAVAIL & INTERFACES UTILISATEUR
  # =========================================================================

  # 7.1 Interface Chat & RAG - Open WebUI (Service Natif NixOS)
  services.open-webui = {
    enable = true;
    port = 8082;
    environment = {
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
    };
  };

  # 7.4 Orchestrateur Système - n8n (Service Natif NixOS)
  services.n8n = {
    enable = true;
    environment = {
      N8N_PORT = "5678";
    };
  };
}