{ config, pkgs, lib, ... }:

let
  local = import ./local.nix;

  # =========================================================================
  # CENTRALISATION DES PARAMÈTRES ET MAILLAGE RÉSEAU (N0 ➔ N7)
  # =========================================================================
  cfg = {
    rocmGfx = "10.3.0"; # Version ROCm spoofée pour RDNA2/RDNA3

    # Table unifiée des ports
    ports = {
      ollama        = 11434;
      mistralrs     = 1234;
      llamacpp      = 8085;
      qdrantHttp    = 6333;
      qdrantGrpc    = 6334;
      tei           = 8080;
      cognee        = 8000;
      redis         = 6379;
      postgres      = 5432;
      litellm       = 4000;
      guardrails    = 8005;
      omniroute     = 3000;
      langfuse      = 3001;
      searxng       = 8888;
      perplexica    = 3005;
      gptresearcher = 8006;
      anythingllm   = 3002;
      difyWeb       = 3003;
      difyApi       = 5001;
      openwebui     = 8082;
      n8n           = 5678;
    };

    # Endpoints vus depuis l'hôte NixOS
    endpoints = {
      ollama    = "http://127.0.0.1:11434";
      mistralrs = "http://127.0.0.1:1234/v1";
      llamacpp  = "http://127.0.0.1:8085/v1";
      qdrant    = "http://127.0.0.1:6333";
      tei       = "http://127.0.0.1:8080/v1";
      cognee    = "http://127.0.0.1:8000";
      omniroute = "http://127.0.0.1:3000/v1";
      searxng   = "http://127.0.0.1:8888";
    };

    # Endpoints vus depuis le réseau interne Docker bridge
    dockerEndpoints = {
      omniroute  = "http://host.docker.internal:3000/v1";
      guardrails = "http://host.docker.internal:8005/v1";
      litellm    = "http://host.docker.internal:4000/v1";
      ollama     = "http://host.docker.internal:11434";
      qdrant     = "http://host.docker.internal:6333";
      tei        = "http://host.docker.internal:8080/v1";
      searxng    = "http://host.docker.internal:8888";
      cognee     = "http://host.docker.internal:8000";
      langfuse   = "http://host.docker.internal:3001";
    };
  };
in

{
  # OUVERTURE EFFECTIVE DU PARE-FEU NIXOS
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      cfg.ports.omniroute 
      cfg.ports.litellm 
      cfg.ports.postgres 
      cfg.ports.n8n 
      cfg.ports.qdrantHttp 
      cfg.ports.redis 
      cfg.ports.cognee 
      cfg.ports.guardrails 
      cfg.ports.tei 
      cfg.ports.openwebui 
      cfg.ports.searxng 
      cfg.ports.ollama 
      cfg.ports.mistralrs 
      cfg.ports.langfuse 
      cfg.ports.anythingllm 
      cfg.ports.perplexica 
      cfg.ports.gptresearcher 
      cfg.ports.difyWeb 
      cfg.ports.difyApi 
    ];
    trustedInterfaces = [ "docker0" ];
  };

  # =========================================================================
  # PAQUETS SYSTÈME GÉNÉRAUX & OUTILS CLI IA
  # =========================================================================

  # Services applicatifs annexes
  services.redis.servers.llm-cache = {
    enable = true;
    port = 6379;
    settings = {
      maxmemory = "2gb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # =========================================================================
  # NIVEAU 0 : ACCÉLÉRATION MATÉRIELLE & RUNTIME BAS NIVEAU (AMD ROCm)
  # =========================================================================

  # 0.1 Pilotage Matériel & Drivers ROCm / HIP
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelModules = [ "amdgpu" "kvm-amd" ];
  boot.kernelParams = [
    "amdgpu.vm_fragment_size=9"
    "amdgpu.ppfeaturemask=0xffffffff"
    "amdgpu.gpu_recovery=1"
    "amdgpu.dpm=1"
  ];
  boot.kernel.sysctl = {
    "vm.max_map_count" = lib.mkForce 2147483642;
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
    "d /var/lib/tei-embeddings 0775 root root - -"
    "d /var/lib/axolotl 0775 root root - -"
    "d /var/lib/axolotl/configs 0775 root root - -"
    "d /var/lib/axolotl/data 0775 root root - -"
    "d /var/lib/axolotl/outputs 0775 root root - -"
    "d /var/lib/axolotl/hf-cache 0775 root root - -"
    # Chemins de persistance Docker :
    "d /var/lib/omniroute 0775 root root - -"
    "d /var/lib/langfuse 0775 root root - -"
    "d /var/lib/dify 0775 root root - -"
    "d /var/lib/anythingllm 0775 root root - -"
    "d /var/lib/perplexica 0775 root root - -"
    "d /etc/perplexica 0755 root root - -"
    "f+ /etc/perplexica/config.toml 0644 root root - -"
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

      # 1.4 Fine-Tuning Sans-Code (Axolotl ROCm)
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

      # 2.3 Embeddings & Rerank (HuggingFace TEI)
      tei-embeddings = {
        image = "ghcr.io/huggingface/text-embeddings-inference:cpu-1.6";
        ports = [ "${toString cfg.ports.tei}:80" ];
        volumes = [
          "/var/lib/tei-embeddings:/data"
        ];
        cmd = [
          "--model-id" "BAAI/bge-large-en-v1.5"
          "--port" "80"
          "--max-concurrent-requests" "512"
          "--max-batch-tokens" "16384"
        ];
      };

      # 3.1 Façade Utilisateur (OmniRoute) -> Intercepte et force le passage via Guardrails
      omniroute = {
        image = "diegosouzapw/omniroute:latest";
        ports = [ "3000:20128" ];
        volumes = [ "/var/lib/omniroute:/app/data" ];
        environment = {
          # MAILLAGE STRICT : Transfert vers Guardrails (N4.2) et non LiteLLM
          FORWARD_BASE_URL = "http://host.docker.internal:8005/v1"; 
          
          # Télémétrie OmniRoute -> Langfuse (N5.4)
          LANGFUSE_HOST = "http://host.docker.internal:3001";
          LANGFUSE_PUBLIC_KEY = "pk-lf-local-key";
          LANGFUSE_SECRET_KEY = "sk-lf-local-key";
          
          REDIS_URL = "redis://host.docker.internal:6379"; # Cache sémantique (N3.3)
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 5.4 Observabilité & Tracing (Langfuse)
      langfuse-server = {
        image = "langfuse/langfuse:2";
        ports = [ "3001:3000" ];
        volumes = [ "/var/lib/langfuse:/app/uploads" ];
        environment = {
          NODE_ENV = "production";
          DATABASE_URL = "postgresql://langfuse:langfuse@host.docker.internal:5432/langfuse";
          REDIS_HOST = "host.docker.internal";
          REDIS_PORT = "6379";
          NEXTAUTH_URL = "http://localhost:3001";
          NEXTAUTH_SECRET = "secret-langfuse-local";
          SALT = "salt-langfuse-local";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.3 Perplexica (Search IA)
      perplexica-app = {
        image = "itshasbulla/perplexica-backend:latest";
        ports = [ "${toString cfg.ports.perplexica}:3000" ];
        volumes = [
          "/etc/perplexica/config.toml:/usr/src/app/config.toml"
          "/var/lib/perplexica:/usr/src/app/data"
        ];
        environment = {
          SEARXNG_API_URL = cfg.dockerEndpoints.searxng;
          OPENAI_API_KEY = "sk-litellm-local-root-key";
          OPENAI_API_URL = cfg.dockerEndpoints.omniroute;
          EMBEDDING_API_URL = cfg.dockerEndpoints.omniroute;
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 6.4 GPT Researcher
      gpt-researcher = {
        image = "gptresearcher/gpt-researcher:latest";
        ports = [ "${toString cfg.ports.gptresearcher}:8000" ];
        environment = {
          SEARXNG_BASE_URL = cfg.dockerEndpoints.searxng;
          OPENAI_BASE_URL = cfg.dockerEndpoints.omniroute;
          OPENAI_API_KEY = "sk-litellm-local-root-key";
          FAST_LLM_MODEL = "openai/qwen-coder-fast";
          SMART_LLM_MODEL = "openai/ollama-general";
          EMBEDDING_PROVIDER = "custom";
          # MAILLAGE CORRIGÉ : Rapatriement de l'URL d'embedding sur la façade
          CUSTOM_EMBEDDING_ENDPOINT = cfg.dockerEndpoints.omniroute;
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };

      # 7.2 Workspace RAG Isolé (AnythingLLM)
      anythingllm = {
        image = "mintplexlabs/anythingllm:latest";
        ports = [ "3002:3001" ];
        volumes = [
          "/var/lib/anythingllm:/app/server/storage"
        ];
        environment = {
          STORAGE_DIR = "/app/server/storage";
          DISABLE_TELEMETRY = "true";

          LLM_PROVIDER = "openai";
          OPEN_AI_KEY = "sk-litellm-local-root-key";
          OPEN_AI_MODEL_PREF = "qwen-coder-fast";
          OPENAI_BASE_PATH = "http://host.docker.internal:3000/v1";

          # MAILLAGE CORRIGÉ : Embeddings via OmniRoute au lieu de TEI direct
          EMBEDDING_ENGINE = "openai";
          EMBEDDING_BASE_PATH = "http://host.docker.internal:3000/v1";
          EMBEDDING_MODEL_PREF = "bge-embeddings";

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

      # 7.3 Plateforme de workflows d'agents (Dify API) -> Redirigé sur OmniRoute (N3.1) + Cognee (N2.4)
      dify-api = {
        image = "langgenius/dify-api:latest";
        ports = [ "5001:5001" ];
        volumes = [ "/var/lib/dify:/app/api/storage" ];
        environment = {
          DB_USERNAME = "dify";
          DB_PASSWORD = "";
          DB_DATABASE = "dify";
          DB_HOST = "host.docker.internal";
          DB_PORT = "5432";

          REDIS_HOST = "host.docker.internal";
          REDIS_PORT = "6379";

          VECTOR_STORE = "qdrant";
          QDRANT_URL = "http://host.docker.internal:6333";

          # Liaison N3.1 (OmniRoute Façade) & N2.4 (Cognee)
          OPENAI_API_BASE = "http://host.docker.internal:3000/v1";
          OPENAI_API_KEY = "sk-litellm-local-root-key";
          COGNEE_API_URL = "http://host.docker.internal:8000";
        };
        extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
      };
    };
  };

  # =========================================================================
  # NIVEAU 3 : ROUTAGE HYBRIDE, PASSERELLE DOUBLE-COUCHE & CASCHING SÉMANTIQUE
  # =========================================================================

  # 3.2 Proxy Backend (LiteLLM)
  services.litellm = {
    enable = true;
    host = "0.0.0.0";
    port = 4000;
    
    # Injection des clés systemd pour la liaison N3.2 ➔ N5.4 (Langfuse)
    environment = {
      LANGFUSE_HOST = "http://127.0.0.1:3001";
      LANGFUSE_PUBLIC_KEY = "pk-lf-9c4a87fb-c5cf-4959-860a-bde8e3cd5b90";
      LANGFUSE_SECRET_KEY = "sk-lf-3a04243c-ee3d-457e-92e2-3664073ad3f2";
    };

    settings = {
      general_settings = {
        master_key = "sk-litellm-local-root-key";
        store_model_in_db = false;
      };
      litellm_settings = {
        drop_params = true;
        set_verbose = false;
        request_timeout = 600;
        num_retries = 3;
        
        success_callbacks = [ "langfuse" ];
        failure_callbacks = [ "langfuse" ];
        
        # Liaison N3.2 ➔ N3.3 (Cache Sémantique Redis)
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
        {
          model_name = "qwen-coder-fast";
          litellm_params = {
            model = "openai/Qwen/Qwen2.5-Coder-7B-Instruct";
            api_base = cfg.endpoints.mistralrs;
            api_key = "none";
          };
        }
        {
          model_name = "ollama-general";
          litellm_params = {
            model = "ollama/qwen2.5-coder:14b";
            api_base = cfg.endpoints.ollama;
            stream = true;
          };
        }
        {
          model_name = "deepseek-r1";
          litellm_params = {
            model = "ollama/deepseek-r1:14b";
            api_base = cfg.endpoints.ollama;
            stream = true;
          };
        }
        {
          model_name = "qwen-gguf";
          litellm_params = {
            model = "openai/qwen-1.5b";
            api_base = cfg.endpoints.llamacpp;
            api_key = "none";
          };
        }
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

  # 5.4 Base de données relationnelle partagée
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    settings = {
      listen_addresses = "*";
      max_connections = 100;
      shared_buffers = "512MB";
    };
    ensureDatabases = [ "langfuse" "dify" ];
    ensureUsers = [
      { name = "langfuse"; ensureDBOwnership = true; }
      { name = "dify"; ensureDBOwnership = true; }
    ];
    # Maintien de l'authentification locale autorisée
    authentication = pkgs.lib.mkOverride 10 ''
      local   all             all                                     trust
      host    all             all             0.0.0.0/0               trust
      host    all             all             127.0.0.1/32            trust
    '';
  };

  # =========================================================================
  # NIVEAU 6 : INGESTION WEB HAUTE VITESSE, SEARCH IA & AGENTS CLI
  # =========================================================================

  # 6.3 Moteur de recherche Méta (SearXNG)
  services.searx = {
    enable = true;
    settings = {
      server = {
        port = 8888;
        bind_address = "0.0.0.0";
        secret_key = "searxng-secret-key-local";
      };
      search = {
        safe_search = 0;
        autocomplete = "duckduckgo";
        formats = [ "html" "json" ]; # Obligatoire pour la consommation RAG / Agents
      };
      outgoing = {
        request_timeout = 5.0;
        user_agent = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
      };
      engines = [
        { name = "duckduckgo"; engine = "duckduckgo"; disabled = false; }
        { name = "google"; engine = "google"; disabled = false; }
        { name = "bing"; engine = "bing"; disabled = false; }
        { name = "wikidata"; engine = "wikidata"; disabled = false; }
        { name = "wikipedia"; engine = "wikipedia"; disabled = false; }
      ];
    };
  };

  # =========================================================================
  # NIVEAU 7 : WORKFLOWS AUTOMATISÉS, ESPACES DE TRAVAIL & INTERFACES UTILISATEUR
  # =========================================================================

  # 7.1 Interface Utilisateur Principale (Pointée directement sur LiteLLM Proxy N3.2)
  services.open-webui = {
    enable = true;
    port = 8082;
    environment = {
      OLLAMA_BASE_URL = cfg.endpoints.ollama;
      OPENAI_API_BASE_URL = "http://127.0.0.1:3000/v1";
      OPENAI_API_KEY = "sk-litellm-local-root-key";
      ENABLE_RAG_WEB_SEARCH = "true";
      RAG_WEB_SEARCH_ENGINE = "searxng";
      RAG_WEB_SEARCH_SEARXNG_QUERY_URL = "http://127.0.0.1:8888/search?q=<query>";
    };
  };

  # 7.4 Workflows d'automatisation (n8n)
  services.n8n = {
    enable = true;
    environment = {
      N8N_PORT = toString cfg.ports.n8n;

      # Liaison N3.1 (OmniRoute Façade)
      OPENAI_API_BASE = "http://127.0.0.1:3000/v1";
      OPENAI_API_KEY = "sk-litellm-local-root-key";

      # Liaison N2.4 (Cognee)
      COGNEE_URL = "http://127.0.0.1:8000";

      # Liaison N6.3 (SearXNG)
      SEARXNG_URL = "http://127.0.0.1:8888";

      # Liaison N2.1 (Qdrant)
      QDRANT_URL = "http://127.0.0.1:6333";
    };
  };

  # =========================================================================
  # ORDONNANCEMENT SYSTEMD (MAILLAGE INTER-SERVICES)
  # =========================================================================

  # S'assure que Cognee démarre uniquement lorsque Qdrant, Ollama et TEI sont fonctionnels
  systemd.services.cognee-service = {
    description = "Cognee Memory & Knowledge Graph Service";
    after = [ "network.target" "qdrant.service" "litellm.service" ];
    wants = [ "qdrant.service" "litellm.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ 
      pkgs.python3 
      pkgs.git 
      pkgs.gcc 
      pkgs.bash 
      pkgs.stdenv.cc.cc 
      pkgs.cacert 
      pkgs.uv 
      pkgs.zlib
      pkgs.openssl
      pkgs.pkg-config
    ];
    environment = {
      HOME = "/var/lib/cognee-service";
      UV_CACHE_DIR = "/var/lib/cognee-service/.cache/uv";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      LD_LIBRARY_PATH = "${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.openssl pkgs.glibc ]}";
      
      # Configuration LLM officielle Cognee -> LiteLLM Proxy (N3.2)
      LLM_PROVIDER = "openai";
      LLM_MODEL = "qwen-coder-fast";
      LLM_ENDPOINT = "http://127.0.0.1:4000/v1";
      LLM_API_KEY = "sk-litellm-local-root-key";

      # Vector Database -> Qdrant (N2.1)
      VECTOR_DB_PROVIDER = "qdrant";
      QDRANT_HOST = "127.0.0.1";
      QDRANT_PORT = "6333";

      # Embeddings -> LiteLLM Proxy (bge-embeddings)
      EMBEDDING_PROVIDER = "openai";
      EMBEDDING_ENDPOINT = "http://127.0.0.1:4000/v1";
      EMBEDDING_MODEL = "bge-embeddings";
      EMBEDDING_DIMENSIONS = "1024";
      EMBEDDING_API_KEY = "sk-litellm-local-root-key";
    };
    preStart = ''
      if [ ! -d /var/lib/cognee-service/cognee ]; then
        ${pkgs.git}/bin/git clone https://github.com/topoteretes/cognee.git /var/lib/cognee-service/cognee
      else
        cd /var/lib/cognee-service/cognee && ${pkgs.git}/bin/git pull origin main
      fi

      cd /var/lib/cognee-service/cognee
      ${pkgs.uv}/bin/uv venv --python ${pkgs.python3}/bin/python .venv --allow-existing
      ${pkgs.uv}/bin/uv pip install --python .venv --upgrade pip setuptools wheel
      ${pkgs.uv}/bin/uv pip install --python .venv -e ".[qdrant]" uvicorn fastapi
    '';
    serviceConfig = {
      StateDirectory = "cognee-service";
      WorkingDirectory = "/var/lib/cognee-service/cognee";
      ExecStart = "/var/lib/cognee-service/cognee/.venv/bin/python -m uvicorn cognee.api.client:app --host 0.0.0.0 --port 8000";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # La télémétrie et la base de données doivent être prêtes en premier
  systemd.services."docker-langfuse-server" = {
    after = [ "postgresql.service" "redis-llm-cache.service" ];
    wants = [ "postgresql.service" "redis-llm-cache.service" ];
  };

  # LiteLLM dépend des backends N1 et de Langfuse
  systemd.services."litellm" = {
    after = [ 
      "docker-langfuse-server.service"
      "redis-llm-cache.service" 
      "ollama.service" 
      "mistralrs.service" 
      "llama-cpp-server.service" 
      "docker-tei-embeddings.service" 
    ];
    wants = [ "docker-langfuse-server.service" ];
  };

  # Tunnel de routage strict : LiteLLM <- Guardrails <- OmniRoute
  systemd.services."docker-omniroute" = {
    after = [ "guardrails-api.service" "docker-langfuse-server.service" ];
    wants = [ "guardrails-api.service" "docker-langfuse-server.service" ];
  };

  # Accès GPU pour le conteneur TEI
  systemd.services."docker-tei-embeddings" = {
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
  };

  # Dépendances applicatives N6 & N7 sur la façade OmniRoute
  systemd.services."docker-perplexica-app" = {
    after = [ "docker-omniroute.service" "searx.service" "docker-tei-embeddings.service" ];
    wants = [ "docker-omniroute.service" "searx.service" "docker-tei-embeddings.service" ];
    unitConfig = {
      StartLimitIntervalSec = 60;
      StartLimitBurst = 10;
    };
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services."docker-gpt-researcher" = {
    after = [ "docker-omniroute.service" "searx.service" "docker-tei-embeddings.service" ];
    wants = [ "docker-omniroute.service" "searx.service" "docker-tei-embeddings.service" ];
  };

  systemd.services."docker-dify-api" = {
    after = [ "postgresql.service" "redis-llm-cache.service" "qdrant.service" "litellm.service" ];
    wants = [ "postgresql.service" "redis-llm-cache.service" "qdrant.service" "litellm.service" ];
  };

  # Open WebUI et n8n passent via OmniRoute (N3.1)
  systemd.services."open-webui" = {
    after = [ "docker-omniroute.service" "searx.service" "cognee-service.service" ];
    wants = [ "docker-omniroute.service" "searx.service" "cognee-service.service" ];
  };

  systemd.services."n8n" = {
    after = [ "docker-omniroute.service" "searx.service" "qdrant.service" "cognee-service.service" ];
    wants = [ "docker-omniroute.service" "searx.service" "qdrant.service" "cognee-service.service" ];
  };

  # Guardrails AI Server
  systemd.services.guardrails-api = {
    description = "Guardrails AI Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ 
      pkgs.python3 
      pkgs.git 
      pkgs.gcc 
      pkgs.bash 
      pkgs.stdenv.cc.cc 
      pkgs.cacert 
      pkgs.uv 
      pkgs.zlib
      pkgs.openssl
    ];
    environment = {
      HOME = "/var/lib/guardrails-api";
      GUARDRAILS_TELEMETRY = "false";
      OTEL_SDK_DISABLED = "true";
      UV_PYTHON = "${pkgs.python3}/bin/python";
      UV_CACHE_DIR = "/var/lib/guardrails-api/.cache/uv";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      LD_LIBRARY_PATH = "${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.openssl pkgs.glibc ]}";
    };
    serviceConfig = {
      StateDirectory = "guardrails-api";
      ExecStartPre = "${pkgs.writeShellScript "init-guardrails-config" ''
        if [ ! -f /var/lib/guardrails-api/config.py ]; then
          echo 'from guardrails import Guard' > /var/lib/guardrails-api/config.py
          echo 'guard = Guard()' >> /var/lib/guardrails-api/config.py
        fi
      ''}";
      ExecStart = "${pkgs.uv}/bin/uvx --from guardrails-ai guardrails start --port 8005 --config /var/lib/guardrails-api/config.py";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}