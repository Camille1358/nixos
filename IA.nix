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

  # =========================================================================
  # NIVEAU 5 : PROTOCOLE MCP, FRAMEWORKS D'AGENTS & OBSERVABILITÉ
  # =========================================================================

  # 5.4 Base de données PostgreSQL dédiée à l'observabilité LLMOps (Langfuse)
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "langfuse" ];
    ensureUsers = [
      {
        name = "langfuse";
        ensureDBOwnership = true;
      }
    ];
    # Authentification locale sans mot de passe pour le conteneur
    authentication = pkgs.lib.mkOverride 10 ''
      # type  database        user            address                 method
      local   all             all                                     trust
      host    langfuse        langfuse        172.17.0.0/16           trust
    '';
  };

  # 5.4 Conteneur OCI Langfuse (Port 3001)
  # À fusionner à l'intérieur de ton bloc `virtualisation.oci-containers.containers`
  virtualisation.oci-containers.containers = {
    langfuse-server = {
      image = "langfuse/langfuse:2";
      ports = [ "3001:3000" ];
      environment = {
        DATABASE_URL = "postgresql://langfuse@172.17.0.1:5432/langfuse?sslmode=disable";
        NEXTAUTH_URL = "http://localhost:3001";
        NEXTAUTH_SECRET = "secret_de_dev_a_changer_en_prod_123456789";
        SALT = "salt_de_dev_a_changer_123456789";
        TELEMETRY_ENABLED = "false";
      };
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };
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

  # 6.3 & 6.4 Conteneurs OCI pour Perplexica et GPT Researcher
  virtualisation.oci-containers.containers = {
    # 6.3 Perplexica (Interface & API de recherche IA)
    perplexica-app = {
      image = "itshasbulla/perplexica:latest";
      ports = [ "3000:3000" ];
      environment = {
        SEARXNG_API_URL = "http://host.docker.internal:8888";
        OLLAMA_API_URL = "http://host.docker.internal:11434";
      };
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };

    # 6.4 GPT Researcher (Agent autonome de recherche approfondie)
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

  # 7.2 & 7.3 Conteneurs OCI pour AnythingLLM et Dify
  virtualisation.oci-containers.containers = {
    # 7.2 Workspace RAG Isolé (AnythingLLM)
    anythingllm = {
      image = "mintplexlabs/anythingllm:latest";
      ports = [ "3002:3001" ];
      volumes = [
        "anythingllm_data:/app/server/storage"
      ];
      environment = {
        STORAGE_DIR = "/app/server/storage";
      };
    };

    # 7.3 Studio Visuel d'Agents - Interface Web (Dify)
    dify-web = {
      image = "langgenius/dify-web:latest";
      ports = [ "3003:3000" ];
      environment = {
        CONSOLE_API_URL = "http://localhost:5001";
        APP_API_URL = "http://localhost:5001";
      };
    };

    # 7.3 Studio Visuel d'Agents - Moteur API (Dify)
    dify-api = {
      image = "langgenius/dify-api:latest";
      ports = [ "5001:5001" ];
      environment = {
        MODE = "api";
        LOG_LEVEL = "INFO";
      };
    };
  };
}