{ pkgs }:

let
  #-----------------------------------------------IA------------------------------------------------
  # 6.1 Dérivation personnalisée Nix pour Spider CLI via GitHub
  spider-cli = pkgs.rustPlatform.buildRustPackage rec {
    pname = "spider_cli";
    version = "2.2.0";

    src = pkgs.fetchFromGitHub {
      owner = "spider-rs";
      repo = "spider";
      rev = "v${version}";
      hash = "sha256-b4JLe0STxPR1Y0y0lpGm3sH9ehXDHhxl36cq/5Lw0NQ=";
    };

    # Remplacement de pkgs.lib.fakeHash par le hash réel pour autoriser le build
    cargoHash = "sha256-k7Ug3rDrreTXjX/KjoQhgyd99aWXkqrn8xXZlFy7uFk="; 
    buildAndCheckSubdir = "spider_cli";

    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ];
  };

  # 5.3 Framework Agent Graph (PydanticAI)
  pydantic-ai = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pydantic_ai_slim";
    version = "0.0.18";
    format = "pyproject";
    src = pkgs.python3Packages.fetchPypi {
      pname = "pydantic_ai_slim";
      inherit version;
      hash = "sha256-DvbHn+GvS9le888ZvE9WbDDzwhtljjaJqPIPxzJCEtA=";
    };
    doCheck = false;
    dontCheckRuntimeDeps = true; # Désactive la vérification stricte des dépendances runtime optionnelles

    nativeBuildInputs = [ pkgs.python3Packages.hatchling ];
    propagatedBuildInputs = with pkgs.python3Packages; [
      pydantic
      httpx
      griffe
      eval-type-backport
    ];
  };

  # 6.2 Conversion Markdown LLM (Crawl4AI)
  crawl4ai = pkgs.python3Packages.buildPythonPackage rec {
    pname = "crawl4ai";
    version = "0.4.247";
    format = "setuptools";
    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-pGTb9hsM1RK7OHBpDmgWjAPc2ZP4YzY7isDKNhRWUIA=";
    };
    doCheck = false;
    
    # Correction du build sandbox Nix
    preBuild = ''
      export HOME=$(mktemp -d)
    '';

    propagatedBuildInputs = with pkgs.python3Packages; [
      pydantic
      httpx
      beautifulsoup4
    ];
  };
in
ps: with ps; [
  lancedb
  pyarrow
  pydantic
  pydantic-core
  langgraph
  mcp
  spider-cli
  pydantic-ai
  crawl4ai
]