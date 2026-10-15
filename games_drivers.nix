# Jeux : pilotes graphiques, réglages du noyau, Steam / Proton, outils.
# Tout ce qui sert à faire tourner les jeux au mieux est regroupé ici.
{ config, lib, pkgs, ... }:

let
  local = import ./local.nix;

  # Réglage du Ryzen 9 7950X3D : ses deux moitiés ne se valent pas en jeu.
  #   "cache"     = privilégie les 8 cœurs au gros cache 3D (meilleurs en jeu)
  #   "frequency" = privilégie les 8 cœurs les plus rapides (meilleurs pour le reste)
  x3d = "/sys/bus/platform/drivers/amd_x3d_vcache/AMDI0101:00/amd_x3d_mode";
  modeX3D = mode: pkgs.writeShellScript "x3d-${mode}" ''
    [ -w ${x3d} ] && echo ${mode} > ${x3d}
    exit 0
  '';
in
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ---------------------------------------------------------------------------
  # Noyau
  # ---------------------------------------------------------------------------
  boot = {
    # ntsync : mécanisme du noyau utilisé par les Proton récents pour reproduire plus
    # fidèlement (et plus vite) la synchronisation de Windows.
    kernelModules = [ "ntsync" ];

    kernelParams = [
      "split_lock_detect=off" # évite des saccades avec certains jeux Windows
      "amdgpu.ppfeaturemask=0xffffffff" # débloque les réglages avancés de la carte (utilisés par LACT)
    ];

    # Limite de zones mémoire par programme : certains gros jeux sous Proton dépassent celle par défaut.
    kernel.sysctl."vm.max_map_count" = 2147483642;
  };

  # ---------------------------------------------------------------------------
  # Pilotes graphiques (AMD)
  # ---------------------------------------------------------------------------
  hardware = {
    cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    graphics = {
      enable = true;
      enable32Bit = true; # indispensable : beaucoup de jeux et Steam lui-même sont en 32 bits
    };
    amdgpu = {
      initrd.enable = true; # charge le pilote dès le début du démarrage (pas d'écran noir intermédiaire)
      opencl.enable = true; # calcul sur carte graphique (OpenCL)
    };

    steam-hardware.enable = true; # manettes et casques reconnus par Steam
    xpadneo.enable = true; # manettes Xbox en Bluetooth : plus stable, niveau de batterie
  };

  services.xserver.videoDrivers = [ "amdgpu" ];

  # Rendu OpenGL sur plusieurs cœurs (gain sur les vieux jeux OpenGL).
  environment.variables.mesa_glthread = "true";

  # LACT : courbe de ventilation, limites de puissance et surveillance de la carte graphique
  services.lact.enable = true;

  # ---------------------------------------------------------------------------
  # Steam, Proton, GameMode
  # ---------------------------------------------------------------------------
  programs = {
    steam = {
      enable = true;
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      # Proton-GE apparaît tout seul dans la liste des outils de compatibilité de Steam.
      extraCompatPackages = [ pkgs.proton-ge-bin ];
    };

    gamescope.enable = true;

    # GameMode : optimise la machine pendant un jeu, puis remet tout comme avant.
    # Il ne s'active QUE si le jeu est lancé avec lui. Dans Steam : clic droit sur le jeu
    # > Propriétés > Options de lancement :   gamemoderun %command%
    # (Lutris et Heroic ont une case "GameMode" dans leurs réglages.)
    gamemode = {
      enable = true;
      settings = {
        general.renice = 10; # donne la priorité au jeu sur le reste
        custom = {
          start = "${modeX3D "cache"}";
          end = "${modeX3D "frequency"}";
        };
      };
    };
  };

  # Le groupe "gamemode" autorise GameMode à changer les priorités.
  users.users.${local.sysName}.extraGroups = [ "gamemode" ];

  # Autorise ce même groupe à changer le mode X3D du processeur (sinon réservé à root). [?]
  systemd.tmpfiles.rules = [ "z ${x3d} 0664 root gamemode - -" ];

  # ---------------------------------------------------------------------------
  # Outils
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    lutris-free # jeux hors Steam (GOG, émulateurs...)
    heroic # Epic Games, GOG, Amazon
    protonup-qt # installer d'autres versions de Proton / Wine pour Lutris et Heroic
    mangohud # affichage en jeu : images par seconde, températures. Steam : mangohud %command%
    goverlay # interface de réglage de MangoHud
  ];
}
