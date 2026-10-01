{ config, pkgs, lib, ... }:

let
  local = import ../local.nix;
  pkgs-stable-latest =
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz")
      {
        config.allowUnfree = true;
      };
  pkgs-unstable =
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz")
      {
        config.allowUnfree = true;
      };
in

{
  home = {
    username = local.sysName; # Informations sur l'utilisateur
    homeDirectory = "/home/${local.sysName}";
    sessionVariables = {

      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

      # ----------------------------------------------------------------------
      # MAILLAGE GLOBAL : ROUTAGE, MÉMOIRE ET TÉLÉMÉTRIE
      # ----------------------------------------------------------------------
      # Routage Universel ➔ Façade OmniRoute (N3.1)
      OPENAI_API_BASE = "http://127.0.0.1:3000/v1";
      OPENAI_API_KEY = "sk-litellm-local-root-key";
      
      # Bypass sécurisé pour Guardrails AI (N4.2) si appelé en direct
      GUARDRAILS_API_BASE = "http://127.0.0.1:8005/v1";
      
      # Mémoire Long Terme Globale (N2.4)
      COGNEE_HOST = "http://127.0.0.1:8000";
      COGNEE_API_URL = "http://127.0.0.1:8000";

      # Observabilité LLMOps Névralgique (N5.4 Langfuse)
      LANGFUSE_HOST = "http://127.0.0.1:3001";
      LANGFUSE_PUBLIC_KEY = "pk-lf-9c4a87fb-c5cf-4959-860a-bde8e3cd5b90";
      LANGFUSE_SECRET_KEY = "sk-lf-3a04243c-ee3d-457e-92e2-3664073ad3f2";

      # Endpoints d'Ingestion & Moteurs de Recherche (N2.1, N6.3)
      SEARXNG_URL = "http://127.0.0.1:8888";
      QDRANT_URL = "http://127.0.0.1:6333";

      # ----------------------------------------------------------------------
      # NIVEAU 4.3 : HARNAIS RUFLO (Connecté au maillage)
      # ----------------------------------------------------------------------
      RUFLO_LLM_ENDPOINT = "http://127.0.0.1:3000/v1";
      RUFLO_TELEMETRY_HOST = "http://127.0.0.1:3001";
      RUFLO_WORKTREE_ROOT = "/var/lib/ruflo/worktrees";
      RUFLO_DEFAULT_MODEL = "qwen-coder-fast";
    };
    packages = with pkgs; [
      #-------------------------------------------------IA------------------------------------------------
      opencode
      docker-compose
      llama-cpp-rocm
      mistral-rs
      clinfo
      rocmPackages.rocminfo
      rocmPackages.rocm-smi
      # 4.1, 4.2 & 4.3
      nodejs
      cargo
      rustc
      rust-analyzer
      gcc
      rustPlatform.rustLibSrc
      uv # Executera instantanément Guardrails AI, MCP et RuFlo via virtualenv légers
      

      (pkgs.symlinkJoin {
        name = "appflowy-wrapped";
        paths = [ pkgs.appflowy ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/appflowy \
            --set AI_OPENAI_API_KEY "sk-litellm-local-root-key" \
            --set AI_OPENAI_HOST "http://127.0.0.1:3000/v1" \
            --set OLLAMA_HOST "http://127.0.0.1:3000" 
        '';
      })
    ];
  };

  # 5.1 Protocole MCP - Connexions directes aux services de la stack
  home.file.".config/opencode/mcp_servers.json".text = builtins.toJSON {
    mcpServers = {
      searxng = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mcp-searxng" "--searxng-url" "http://127.0.0.1:8888" ];
      };
      qdrant = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mcp-server-qdrant" "--qdrant-url" "http://127.0.0.1:6333" ];
      };
      spider = {
        command = "${pkgs.nodejs}/bin/npx";
        args = [ "-y" "spider-mcp" ];
      };
      cognee = {
        command = "${pkgs.uv}/bin/uvx";
        args = [ "mcp-server-cognee" "--cognee-url" "http://127.0.0.1:8000" ];
      };
    };
  };
}
