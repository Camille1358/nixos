# Outils IA qui n'existent pas dans nixpkgs.
#
# Deux familles :
#   1. COMPILÉS par Nix depuis une source épinglée dans flake.nix (Go, Rust) :
#      reproductibles, vérifiés par empreinte.
#   2. LANCEURS : petits scripts qui démarrent une version PRÉCISE d'un outil npm ou
#      Python (via npx / uvx). L'outil est téléchargé au premier lancement puis gardé
#      en cache. Moins strict que la famille 1 (pas d'empreinte côté Nix), mais la
#      version est figée dans parametres.nix : rien ne se met à jour tout seul.
#
# Utilisé par IA/home.nix (outils en ligne de commande) et IA/systeme/*.nix (services).
{ pkgs, lib, inputs, p }:

let
  # Bibliothèques dont ont besoin les modules précompilés téléchargés par npm / uv
  # (ils sont prévus pour une distribution Linux classique, pas pour NixOS).
  libs = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.openssl ];

  # Lanceur d'un paquet npm à une version donnée.
  npx = { name, package, version, bin ? name, env ? { } }:
    pkgs.writeShellScriptBin name ''
      # bash, sed, grep... : les scripts d'installation de npm en ont besoin, et un service
      # systemd ne les a pas d'office dans son PATH (cause d'un plantage en boucle constaté).
      export PATH=${lib.makeBinPath [ pkgs.nodejs_24 pkgs.git pkgs.coreutils pkgs.bash pkgs.gnused pkgs.gnugrep pkgs.gawk pkgs.findutils pkgs.which ]}:$PATH
      export npm_config_cache=''${npm_config_cache:-${p.dossier}/outils/npm}
      export LD_LIBRARY_PATH=${libs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env)}
      exec npx --yes --package=${package}@${version} -- ${bin} "$@"
    '';

  # Lanceur d'un paquet Python (PyPI) à une version donnée, avec le Python de Nix.
  uvx = { name, package, version, bin ? name, env ? { } }:
    pkgs.writeShellScriptBin name ''
      export PATH=${lib.makeBinPath [ pkgs.uv pkgs.git pkgs.coreutils pkgs.bash pkgs.gnused pkgs.gnugrep pkgs.findutils ]}:$PATH
      export UV_PYTHON=${pkgs.python312}/bin/python3
      export UV_PYTHON_DOWNLOADS=never
      export UV_CACHE_DIR=''${UV_CACHE_DIR:-${p.dossier}/outils/uv}
      export UV_TOOL_DIR=''${UV_TOOL_DIR:-${p.dossier}/outils/uv/outils}
      export LD_LIBRARY_PATH=${libs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env)}
      exec uvx --from ${package}==${version} ${bin} "$@"
    '';
in
rec {
  inherit libs;

  # ===========================================================================
  # 1. Compilés depuis la source
  # ===========================================================================

  # 2.3 Engram [Go] : mémoire des agents (décisions, préférences), SQLite, serveur MCP
  engram = pkgs.buildGoModule {
    pname = "engram";
    version = p.versions.engram;
    src = inputs.engram-src;
    vendorHash = "sha256-M6+OxF+qigWmjMCEeQn2nvpZqDxh9D4bXewGGUW6QEQ=";
    subPackages = [ "cmd/engram" ];
    ldflags = [ "-s" "-w" ];
    doCheck = false; # les tests du projet veulent le réseau et un vrai dossier personnel
    meta.mainProgram = "engram";
  };

  # 4.6 Open Code Review [Go] : relecture automatique avant chaque commit (commande : ocr)
  ocr = pkgs.buildGoModule {
    pname = "open-code-review";
    version = p.versions.ocr;
    src = inputs.ocr-src;
    vendorHash = "sha256-IN7UpxWn+IyQoLbFXJd8URScg5lo/JFTsC6KCMQoJXE=";
    subPackages = [ "cmd/opencodereview" ];
    # Le projet réclame Go 1.26.9 ; nixpkgs 26.05 fournit 1.26.8 (un simple correctif d'écart).
    postPatch = ''
      sed -i -E 's/^go 1\.26\.[0-9]+$/go 1.26.8/' go.mod
    '';
    ldflags = [ "-s" "-w" ];
    doCheck = false;
    postInstall = "mv $out/bin/opencodereview $out/bin/ocr";
    meta.mainProgram = "ocr";
  };

  # 4.2 jcode [Rust] : second agent (essaims). Attention au nom : c'est 1jehuang/jcode.
  jcode = pkgs.rustPlatform.buildRustPackage {
    pname = "jcode";
    version = p.versions.jcode;
    src = inputs.jcode-src;
    cargoLock = {
      lockFile = "${inputs.jcode-src}/Cargo.lock";
      allowBuiltinFetchGit = true; # 2 dépendances viennent de dépôts Git (épinglés par commit dans Cargo.lock)
    };
    cargoBuildFlags = [ "--bin" "jcode" ];
    nativeBuildInputs = [ pkgs.pkg-config pkgs.cmake pkgs.perl pkgs.protobuf ];
    buildInputs = [ pkgs.openssl pkgs.sqlite pkgs.zlib ];
    doCheck = false;
    meta.mainProgram = "jcode";
  };

  # ===========================================================================
  # 2. Lanceurs à version figée
  # ===========================================================================

  # 3.1 OmniRoute [TS] : la passerelle (lancée comme service dans systeme/passerelle.nix)
  omniroute = npx { name = "omniroute"; package = "omniroute"; version = p.versions.omniroute; };

  # 6.4 Feynman [TS] : recherche approfondie (/deepresearch, /lit...)
  feynman = npx {
    name = "feynman";
    package = "@companion-ai/feynman";
    version = p.versions.feynman;
    env.FEYNMAN_TELEMETRY = "off";
  };

  # 6.3 anydoc [Rust, distribué par npm] : Word, PDF, Excel... -> Markdown
  anydoc = npx { name = "anydoc"; package = "@firecrawl/anydoc"; version = p.versions.anydoc; };

  # 2.4 Graphify [Python] : carte du code et des docs (graph.html interactif).
  # Sur PyPI le paquet s'appelle "graphifyy" (deux y) : c'est bien celui de Graphify-Labs.
  graphify = uvx { name = "graphify"; package = "graphifyy"; version = p.versions.graphify; };

  # 5.2 Serveur MCP pour Qdrant. Son modèle d'embeddings est rangé dans le dossier central
  # (sinon : /tmp, et un nouveau téléchargement après chaque nettoyage).
  mcp-qdrant = uvx {
    name = "mcp-server-qdrant";
    package = "mcp-server-qdrant";
    version = p.versions.mcpQdrant;
    env.FASTEMBED_CACHE_PATH = "${p.dossier}/outils/fastembed";
  };
}
