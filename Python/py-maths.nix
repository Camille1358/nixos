{ pkgs }:

let
  mf-tools = pkgs.python3Packages.buildPythonPackage rec {
    pname = "MF_Tools";
    version = "0.1.0";
    format = "other";
    src = pkgs.fetchFromGitHub {
      owner = "TheMathematicFanatic";
      repo = "MF_Tools";
      rev = "main";
      hash = "sha256-dDWU/+MZSbzs7Z0HOj8p2oJLPuniqu/0tBvNgoK49q4=";
    };
    installPhase = ''
      mkdir -p $out/${pkgs.python3.sitePackages}
      if [ -d "src/MF_Tools" ]; then
        cp -r src/MF_Tools $out/${pkgs.python3.sitePackages}/
      elif [ -d "MF_Tools" ]; then
        cp -r MF_Tools $out/${pkgs.python3.sitePackages}/
      else
        cp -r . $out/${pkgs.python3.sitePackages}/
      fi
    '';
    doCheck = false;
    dontCheckRuntimeDeps = true;
    propagatedBuildInputs = with pkgs.python3Packages; [ manim ];
  };

  mf-algebra = pkgs.python3Packages.buildPythonPackage rec {
    pname = "MF_Algebra";
    version = "0.1.0";
    format = "other";
    src = pkgs.fetchFromGitHub {
      owner = "TheMathematicFanatic";
      repo = "MF_Algebra";
      rev = "main";
      hash = "sha256-aO2FQhkcqphIzfZ0myVOGFV32S+lJlDLxKrKCynYs0U=";
    };
    installPhase = ''
      mkdir -p $out/${pkgs.python3.sitePackages}
      cp -r src/MF_Algebra $out/${pkgs.python3.sitePackages}/
    '';
    doCheck = false;
    dontCheckRuntimeDeps = true;
    propagatedBuildInputs = with pkgs.python3Packages; [ manim mf-tools ];
  };
in
ps: with ps; [
  sympy
  mf-algebra
]