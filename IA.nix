{ config, pkgs, lib, ... }:

let
  local = import ./local.nix;

  # =========================================================================
  # CENTRALISATION DES PARAMÈTRES ET MAILLAGE RÉSEAU (N0, N1, N2)
  # =========================================================================
  cfg = {
    rocmGfx = "10.3.0"; # Version ROCm spoofée pour RDNA2/RDNA3

    # Ports des services
    ports = {
      ollama    = 11434;
      mistralrs = 1234;
      llamacpp  = 8085;
      qdrantHttp= 6333;
      qdrantGrpc= 6334;
      tei       = 8080;
      mem0      = 8081;
    };

    # Endpoints vus depuis l'hôte NixOS
    endpoints = {
      ollama    = "http://127.0.0.1:11434";
      mistralrs = "http://127.0.0.1:1234/v1";
      llamacpp  = "http://127.0.0.1:8085/v1";
      qdrant    = "http://127.0.0.1:6333";
      tei       = "http://127.0.0.1:8080/v1";
      mem0      = "http://127.0.0.1:8081";
    };

    # Endpoints vus depuis les conteneurs Docker (passerelle bridge)
    dockerEndpoints = {
      ollama = "http://host.docker.internal:11434";
      qdrant = "http://host.docker.internal:6333";
      tei    = "http://host.docker.internal:8080/v1";
    };
  };
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
  boot.kernelModules = [ "amdgpu" "kvm-amd" ];
  boot.kernelParams = [
    "amdgpu.vm_fragment_size=9"       # Alignement de page VRAM (réduction de la fragmentation)
    "amdgpu.ppfeaturemask=0xffffffff" # Gestion débridée des fréquences GPU
    "amdgpu.gpu_recovery=1"           # Récupération à chaud sans crash système en cas d'OOM
    "amdgpu.dpm=1"
  ];
  boot.kernel.sysctl = {
    "vm.max_map_count" = lib.mkForce 2147483642; # Priorise cette valeur sur les autres fichiers
  };

  # Déverrouillage des plafonds d'allocation mémoire pour les moteurs ROCm/HIP
  security.pam.loginLimits = [
    { domain = "*"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "*"; item = "nofile";  type = "-"; value = "1048576"; }
    { domain = "*"; item = "nproc";   type = "-"; value = "524288"; }
  ];

  # Drivers graphiques et bibliothèques ROCm / HIP / OpenCL
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

  # Variables d'environnement globales pour le runtime ROCm / PyTorch
  environment.variables = {
    HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx;
    ROC_ENABLE_PRE_VEGA = "0";
    PYTORCH_ROCM_ALLOC_CONF = "max_split_size_mb:512";
    HIP_VISIBLE_DEVICES = "0";
    GPU_MAX_ALLOC_PERCENT = "100";
    GPU_SINGLE_ALLOC_PERCENT = "100";
    AMD_LOG_LEVEL = "0";
  };

  # Lien symbolique requis pour les runtimes HIP/ROCm natifs
  systemd.tmpfiles.rules = [
    "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}"
    "d /var/lib/llama-cpp 0770 root root - -"
    "d /var/lib/mistralrs 0770 root root - -"
    "d /var/lib/qdrant 0750 qdrant qdrant - -"
    # 1.4 Stockage Axolotl
    "d /var/lib/axolotl 0775 root root - -"
    "d /var/lib/axolotl/configs 0775 root root - -"
    "d /var/lib/axolotl/data 0775 root root - -"
    "d /var/lib/axolotl/outputs 0775 root root - -"
    "d /var/lib/axolotl/hf-cache 0775 root root - -"
  ];

  # =========================================================================
  # NIVEAU 1 : INFÉRENCE LOCALE, MODÈLES SPÉCIALISÉS & FINE-TUNING
  # =========================================================================

  # 1.1 Backend Local Général (Ollama ROCm)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    rocmOverrideGfx = cfg.rocmGfx;
    host = "0.0.0.0";
    port = cfg.ports.ollama;

    environmentVariables = {
      HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx;
      OLLAMA_NUM_PARALLEL = "4";
      OLLAMA_MAX_LOADED_MODELS = "2";
      OLLAMA_KEEP_ALIVE = "24h";
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_ORIGINS = "*";
      OLLAMA_KV_CACHE_TYPE = "q4_0";
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
      HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx;
      HSA_ENABLE_SDMA = "0";
      HF_HOME = "/var/lib/mistralrs";
    };

    serviceConfig = {
      ExecStart = ''
        ${pkgs.mistral-rs}/bin/mistralrs-server \
          --port ${toString cfg.ports.mistralrs} \
          plain \
          -m Qwen/Qwen2.5-Coder-7B-Instruct \
          -a qwen2
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "mistralrs";
      LimitMEMLOCK = "infinity";

      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # 1.3 Moteur GGUF/C++ Native (llama.cpp OpenAI API Server)
  systemd.services.llama-cpp-server = {
    description = "Serveur llama.cpp OpenAI Native (Niveau 1.3)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx;
    };

    path = [ pkgs.curl pkgs.llama-cpp-rocm ];

    serviceConfig = {
      ExecStartPre = pkgs.writeShellScript "download-gguf" ''
        if [ ! -f /var/lib/llama-cpp/modele.gguf ]; then
          echo "Téléchargement du modèle GGUF..."
          ${pkgs.curl}/bin/curl -L "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf" -o /var/lib/llama-cpp/modele.gguf
        fi
      '';
      ExecStart = ''
        ${pkgs.llama-cpp-rocm}/bin/llama-server \
          --host 0.0.0.0 \
          --port ${toString cfg.ports.llamacpp} \
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

      SupplementaryGroups = [ "video" "render" ];
    };
  };

  # 1.4 Virtualisation Docker (Liaison N0 ➔ Docker ROCm Passthrough)
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
        http_port = cfg.ports.qdrantHttp;
        grpc_port = cfg.ports.qdrantGrpc;
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

      # 1.4 Fine-Tuning Sans-Code (Axolotl ROCm - Interconnecté à N0 GPU)
      axolotl = {
        image = "winglian/axolotl:main-rocm6.0-py3.10";
        volumes = [
          "/var/lib/axolotl/configs:/workspace/configs"
          "/var/lib/axolotl/data:/workspace/data"
          "/var/lib/axolotl/outputs:/workspace/outputs"
          "/var/lib/axolotl/hf-cache:/root/.cache/huggingface"
        ];
        environment = {
          HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx;
          HSA_ENABLE_SDMA = "0";
          HIP_VISIBLE_DEVICES = "0";
          PYTORCH_ROCM_ALLOC_CONF = "max_split_size_mb:512";
        };
        extraOptions = [
          "--device=/dev/kfd"
          "--device=/dev/dri"
          "--ipc=host"
          "--shm-size=16g"
        ];
      };

      # 2.3 Embeddings & Rerank (HuggingFace TEI - Interconnecté à N0 GPU)
      tei-embeddings = {
        image = "ghcr.io/huggingface/text-embeddings-inference:rocm-1.6";
        ports = [ "${toString cfg.ports.tei}:80" ];
        environment = {
          HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfx; # <--- À AJOUTER
        };
        cmd = [
          "--model-id" "BAAI/bge-large-en-v1.5"
          "--port" "80"
          "--max-concurrent-requests" "512"
          "--max-batch-tokens" "16384"
          "--auto-truncate"
        ];
        # Transmission directe des périphériques ROCm/KFD
        extraOptions = [
          "--device=/dev/kfd"
          "--device=/dev/dri"
        ];
      };

      # 2.4 Service de Mémoire Long Terme (Mem0 - Interconnecté à N1, N2.1, N2.3)
      mem0-service = {
        image = "mem0/mem0:latest";
        ports = [ "${toString cfg.ports.mem0}:8000" ];
        environment = {
          # Connexion à Qdrant (N2.1)
          VECTOR_STORE = "qdrant";
          QDRANT_HOST = cfg.dockerEndpoints.qdrant;

          # Connexion à Ollama (N1.1) pour l'extraction mémoire
          LLM_PROVIDER = "ollama";
          OLLAMA_BASE_URL = cfg.dockerEndpoints.ollama;
          OLLAMA_MODEL = "qwen2.5-coder:14b";

          # Connexion à TEI (N2.3) pour le vector embedding
          EMBEDDING_PROVIDER = "openai";
          OPENAI_BASE_URL = cfg.dockerEndpoints.tei;
          OPENAI_API_KEY = "none";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 3.1 Façade Utilisateur (OmniRoute)
      omniroute = {
        image = "omniroute/omniroute:latest";
        ports = [ "3000:3000" ];
        environment = {
          # Liaison N3.1 ➔ N3.2
          LITELLM_BASE_URL = "http://host.docker.internal:4000";
          LITELLM_API_KEY = "sk-litellm-local-root-key";
          # Liaison N3.1 ➔ N5.4
          LANGFUSE_HOST = "http://host.docker.internal:3001";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 4.2 Filtrage & Sécurité (Guardrails AI Service)
      guardrails-api = {
        image = "guardrails/guardrails:latest";
        ports = [ "8005:8000" ];
        environment = {
          # Restreint la sortie vers le proxy LiteLLM (N3.2)
          OPENAI_API_BASE = "http://host.docker.internal:4000/v1";
          OPENAI_API_KEY = "sk-litellm-local-root-key";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.3 Perplexica (Search IA) - Interconnecté à SearXNG (N6.3), LiteLLM (N3.2) & TEI (N2.3)
      perplexica-app = {
        image = "itshasbulla/perplexica:latest";
        ports = [ "3005:3000" ];
        environment = {
          SEARXNG_API_URL = "http://host.docker.internal:8888";
          OPENAI_API_KEY = "sk-litellm-local-root-key";
          OPENAI_API_URL = "http://host.docker.internal:4000/v1";
          EMBEDDING_API_URL = "http://host.docker.internal:8080/v1";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.4 GPT Researcher
      gpt-researcher = {
        image = "gptresearcher/gpt-researcher:latest";
        ports = [ "8000:8000" ];
        environment = {
          SEARXNG_BASE_URL = "http://host.docker.internal:8888";
          OPENAI_BASE_URL = "http://host.docker.internal:4000/v1";
          OPENAI_API_KEY = "sk-litellm-local-root-key";
          FAST_LLM_MODEL = "openai/qwen-coder-fast";
          SMART_LLM_MODEL = "openai/ollama-general";
          EMBEDDING_PROVIDER = "custom";
          CUSTOM_EMBEDDING_ENDPOINT = "http://host.docker.internal:8080/v1";
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
          
          # Initialisation automatique des clés pour le maillage des SDK (N5.3, N6.5)
          LANGFUSE_INIT_ORG_ID = "default";
          LANGFUSE_INIT_PROJECT_ID = "main";
          LANGFUSE_INIT_PROJECT_PUBLIC_KEY = "pk-lf-local-key";
          LANGFUSE_INIT_PROJECT_SECRET_KEY = "sk-lf-local-key";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 7.2 Workspace RAG Isolé (AnythingLLM) - Interconnecté à LiteLLM (N3.2), TEI (N2.3) & Qdrant (N2.1)
      anythingllm = {
        image = "mintplexlabs/anythingllm:latest";
        ports = [ "3002:3001" ];
        volumes = [
          "/var/lib/anythingllm:/app/server/storage"
        ];
        environment = {
          STORAGE_DIR = "/app/server/storage";
          DISABLE_TELEMETRY = "true";

          # Inférence via LiteLLM (N3.2)
          LLM_PROVIDER = "openai";
          OPEN_AI_KEY = "sk-litellm-local-root-key";
          OPEN_AI_MODEL_PREF = "qwen-coder-fast";
          OPENAI_BASE_PATH = "http://host.docker.internal:4000/v1";

          # Embeddings via TEI (N2.3)
          EMBEDDING_ENGINE = "openai";
          EMBEDDING_BASE_PATH = "http://host.docker.internal:8080/v1";
          EMBEDDING_MODEL_PREF = "BAAI/bge-large-en-v1.5";

          # Vector DB via Qdrant (N2.1)
          VECTOR_DB = "qdrant";
          QDRANT_ENDPOINT = "http://host.docker.internal:6333";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 7.3 Studio Visuel d'Agents (Dify Web) - Port 3003
      dify-web = {
        image = "langgenius/dify-web:latest";
        ports = [ "3003:3000" ];
        environment = {
          CONSOLE_API_URL = "http://localhost:5001";
          APP_API_URL = "http://localhost:5001";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 7.3 Studio Visuel d'Agents (Dify API) - Interconnecté à PostgreSQL (N5.4), Redis (N3.3) & Qdrant (N2.1)
      dify-api = {
        image = "langgenius/dify-api:latest";
        ports = [ "5001:5001" ];
        environment = {
          MODE = "api";
          LOG_LEVEL = "INFO";
          SECRET_KEY = "dify_secret_key_a_changer_en_prod";

          # Base de données PostgreSQL (N5.4)
          DB_HOST = "host.docker.internal";
          DB_PORT = "5432";
          DB_USER = "langfuse";
          DB_PASSWORD = "";
          DB_DATABASE = "langfuse";

          # Cache Redis (N3.3)
          REDIS_HOST = "host.docker.internal";
          REDIS_PORT = "6379";

          # Vector DB Qdrant (N2.1)
          VECTOR_STORE = "qdrant";
          QDRANT_URL = "http://host.docker.internal:6333";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };
    };
  };

  # =========================================================================
  # NIVEAU 3 : ROUTAGE HYBRIDE, PASSERELLE DOUBLE-COUCHE & CASCHING SÉMANTIQUE
  # =========================================================================

  # 3.2 Proxy Backend (LiteLLM) - Centralisation & Routage
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
        
        # Interconnection N3.2 ➔ N5.4 (Observabilité Langfuse)
        success_callbacks = [ "langfuse" ];
        failure_callbacks = [ "langfuse" ];
        
        # Interconnection N3.2 ➔ N3.3 (Cache Sémantique Redis)
        cache = true;
        cache_params = {
          type = "redis";
          host = "127.0.0.1";
          port = 6379;
          namespace = "litellm.cache";
          supported_call_types = [ "completion" "embeddings" ];
        };
      };
      
      # Table de routage unifiée (N1.1, N1.2, N1.3, N2.3)
      model_list = [
        # N1.2 mistral.rs (Inférence ultra-rapide)
        {
          model_name = "qwen-coder-fast";
          litellm_params = {
            model = "openai/Qwen/Qwen2.5-Coder-7B-Instruct";
            api_base = cfg.endpoints.mistralrs;
            api_key = "none";
          };
        }
        # N1.1 Ollama ROCm (Modèle général & raisonnement)
        {
          model_name = "ollama-general";
          litellm_params = {
            model = "ollama/qwen2.5-coder:14b";
            api_base = cfg.endpoints.ollama;
            stream = true;
          };
        }
        # N1.3 llama.cpp (GGUF / Grammaires GBNF N4.1)
        {
          model_name = "qwen-gguf";
          litellm_params = {
            model = "openai/qwen-1.5b";
            api_base = cfg.endpoints.llamacpp;
            api_key = "none";
          };
        }
        # N2.3 TEI (Embeddings locaux)
        {
          model_name = "bge-embeddings";
          litellm_params = {
            model = "openai/BAAI/bge-large-en-v1.5";
            api_base = cfg.endpoints.tei;
            api_key = "none";
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

  # =========================================================================
  # ORDONNANCEMENT SYSTEMD (MAILLAGE INTER-SERVICES)
  # =========================================================================

  # S'assure que Mem0 démarre uniquement lorsque Qdrant, Ollama et TEI sont fonctionnels
  systemd.services."docker-mem0-service" = {
    after = [
      "qdrant.service"
      "ollama.service"
      "docker-tei-embeddings.service"
    ];
    wants = [
      "qdrant.service"
      "ollama.service"
      "docker-tei-embeddings.service"
    ];
  };

  # Accès GPU pour le conteneur TEI
  systemd.services."docker-tei-embeddings" = {
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
  };

  # Maillage des dépendances de démarrage N5 et N6
  systemd.services."docker-perplexica-app" = {
    after = [ "searx.service" "litellm.service" "docker-tei-embeddings.service" ];
    wants = [ "searx.service" "litellm.service" "docker-tei-embeddings.service" ];
  };

  systemd.services."docker-gpt-researcher" = {
    after = [ "searx.service" "litellm.service" "docker-tei-embeddings.service" ];
    wants = [ "searx.service" "litellm.service" "docker-tei-embeddings.service" ];
  };

  systemd.services."docker-langfuse-server" = {
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
  };
}