# NIVEAU 2 : mémoire et données.
# (2.3 Engram et 2.4 Graphify sont des outils utilisateur : voir IA/home.nix.)
{ config, pkgs, lib, ia, iaPaquets, iaCompte, ... }:

{
  # ---------------------------------------------------------------------------
  # 2.1 Base vectorielle : Qdrant — partagée par Open WebUI et les agents (MCP)
  # ---------------------------------------------------------------------------
  services.qdrant = lib.mkIf ia.actif.qdrant {
    enable = true;
    settings = {
      service = {
        host = ia.hote;
        http_port = ia.ports.qdrant;
        grpc_port = ia.ports.qdrantGrpc;
      };
      storage = {
        storage_path = "${ia.dossier}/services/qdrant/storage";
        snapshots_path = "${ia.dossier}/services/qdrant/snapshots";
        on_disk_payload = true; # garde les textes sur disque plutôt qu'en mémoire vive
      };
      telemetry_disabled = true; # 0.5
    };
  };

  systemd.services.qdrant = lib.mkIf ia.actif.qdrant {
    serviceConfig = {
      Slice = "ia.slice";
      MemoryMax = ia.memoireMax.qdrant;
      WorkingDirectory = lib.mkForce "${ia.dossier}/services/qdrant";
    } // iaCompte "services/qdrant";
  };

  # ---------------------------------------------------------------------------
  # 2.2 Mémoire de savoir : Cognee [?]
  # ---------------------------------------------------------------------------
  # Un seul service, que les agents interrogent : son graphe embarqué (Ladybug, ex-Kuzu)
  # est un fichier, qui ne supporte pas d'être ouvert par plusieurs programmes à la fois.
  # Vecteurs : stockage embarqué par défaut de Cognee. Son branchement sur Qdrant passe par
  # un adaptateur communautaire que je n'ai pas pu vérifier ; il n'est donc pas activé.
  # 3.4 Chemin court : Cognee parle directement à llama-swap, pas à OmniRoute.
  systemd.services.cognee = lib.mkIf ia.actif.cognee {
    description = "IA 2.2 : Cognee (mémoire de savoir)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "llama-swap.service" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.uv pkgs.git pkgs.gcc ];
    environment = {
      HOME = "${ia.dossier}/services/cognee";
      UV_PYTHON = "${pkgs.python312}/bin/python3";
      UV_PYTHON_DOWNLOADS = "never";
      UV_CACHE_DIR = "${ia.dossier}/services/cognee/.cache/uv";
      LD_LIBRARY_PATH = iaPaquets.libs;

      LLM_PROVIDER = "custom";
      LLM_MODEL = "openai/${ia.modeleParDefaut}";
      LLM_ENDPOINT = ia.url.llamaSwap;
      LLM_API_KEY = ia.cleLocale;

      EMBEDDING_PROVIDER = "custom";
      EMBEDDING_MODEL = "openai/${ia.modeles.embeddings.nom}";
      EMBEDDING_ENDPOINT = ia.embeddingsUrl;
      EMBEDDING_API_KEY = ia.cleLocale;
      EMBEDDING_DIMENSIONS = toString ia.modeles.embeddings.dimensions;

      DATA_ROOT_DIRECTORY = "${ia.dossier}/services/cognee/donnees";
      SYSTEM_ROOT_DIRECTORY = "${ia.dossier}/services/cognee/systeme";
      TELEMETRY_DISABLED = "1"; # 0.5
    };

    serviceConfig = {
      # Version figée dans parametres.nix ; installée par uv au premier démarrage.
      ExecStart = "${pkgs.uv}/bin/uvx --from cognee==${ia.versions.cognee} --with uvicorn uvicorn cognee.api.client:app --host ${ia.hote} --port ${toString ia.ports.cognee}";
      Slice = "ia.slice";
      WorkingDirectory = "${ia.dossier}/services/cognee";
      MemoryMax = ia.memoireMax.cognee;
      Restart = "always";
      RestartSec = 30;
      TimeoutStartSec = "30min"; # premier démarrage : téléchargement des dépendances
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
    } // iaCompte "services/cognee";
  };
}
