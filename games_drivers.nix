# Jeux : pilotes graphiques, réglages du noyau, Steam / Proton, outils.
# Tout ce qui sert à faire tourner les jeux au mieux est regroupé ici.
{ config, lib, pkgs, ... }:

let
  local = import ./local.nix;

  # ===========================================================================
  # REFROIDISSEMENT (la carte graphique s'éteignait en surchauffe en jeu)
  # ===========================================================================
  # Ventilateurs de la carte graphique, selon la température la plus chaude de la puce
  # ("junction" ; coupure d'urgence à 115 °C) : température → vitesse (0.5 = 50 %).
  courbeCarteGraphique = { "40" = 0.30; "55" = 0.40; "65" = 0.55; "75" = 0.75; "85" = 0.95; "90" = 1.0; };
  # Puissance maximale de la carte, en watts (origine : 272). Un peu moins = beaucoup moins
  # de chaleur pour quelques % d'images par seconde en moins. null = réglage d'origine.
  puissanceCarteGraphique = 240;
  # Ventilateurs du boîtier (boîtier NZXT) : vitesse en % selon la plus chaude des
  # températures carte graphique / processeur. Ils restaient bloqués à 25 %.
  courbeBoitier = [
    { jusqua = 50; vitesse = 35; }
    { jusqua = 60; vitesse = 45; }
    { jusqua = 70; vitesse = 60; }
    { jusqua = 80; vitesse = 80; }
  ]; # au-delà : 100 %
  # ===========================================================================

  # Identifiant de la carte graphique pour LACT (constructeur:modèle-…-emplacement PCI)
  carteGraphique = "1002:73BF-1043:04F2-0000:03:00.0";

  ventilationBoitier = pkgs.writeShellScript "ventilation-boitier" ''
    # Plus haute température (en degrés) parmi la carte graphique et le processeur
    temperature() {
      max=0
      for f in /sys/class/drm/card*/device/hwmon/hwmon*/temp2_input /sys/class/hwmon/hwmon*/temp1_input; do
        [ -r "$f" ] || continue
        case "$(cat "$(dirname "$f")/name")" in amdgpu|k10temp) ;; *) continue ;; esac
        t=$(( $(cat "$f") / 1000 ))
        [ "$t" -gt "$max" ] && max=$t
      done
      echo "$max"
    }
    vitesse() {
      ${lib.concatMapStrings (p: ''[ "$1" -lt ${toString p.jusqua} ] && { echo ${toString p.vitesse}; return; }
      '') courbeBoitier}echo 100
    }
    while true; do
      t=$(temperature)
      pwm=$(( $(vitesse "$t") * 255 / 100 ))
      for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat $h/name)" = nzxtsmart2 ] || continue
        for i in 1 2 3; do
          [ "$(cat $h/pwm''${i}_enable 2>/dev/null)" = 0 ] && continue # rien de branché
          echo "$pwm" > $h/pwm$i 2>/dev/null
        done
      done
      sleep 3
    done
  '';

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
  # Réglages de LACT écrits ici (courbe de ventilation et puissance : voir en haut du fichier).
  # Note : l'application LACT ne peut plus les modifier elle-même, c'est ce fichier qui décide.
  services.lact.settings = {
    version = 5;
    daemon = { log_level = "info"; admin_group = "wheel"; disable_clocks_cleanup = false; };
    apply_settings_timer = 5;
    gpus.${carteGraphique} = {
      fan_control_enabled = true;
      fan_control_settings = {
        mode = "curve";
        static_speed = 0.5;
        temperature_key = "junction";
        interval_ms = 500;
        curve = courbeCarteGraphique;
        spindown_delay_ms = 5000; # ne ralentit qu'après 5 s plus froides (pas de yoyo)
        change_threshold = 2;
      };
    } // lib.optionalAttrs (puissanceCarteGraphique != null) { power_cap = puissanceCarteGraphique * 1.0; };
  };
  # La courbe a pour clés des températures : Nix les écrit entre guillemets ('40':), LACT
  # attend des nombres (40:). On retire les guillemets dans le fichier produit.
  environment.etc."lact/config.yaml".source = lib.mkForce (pkgs.runCommand "lact-config.yaml" { } ''
    sed -E "s/^( +)'([0-9]+)':/\1\2:/" ${(pkgs.formats.yaml { }).generate "lact-brut.yaml" config.services.lact.settings} > $out
  '');

  # Ventilateurs du boîtier : vérifie la température toutes les 3 s et règle leur vitesse
  systemd.services.ventilation-boitier = {
    description = "Ventilateurs du boîtier selon la température";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { ExecStart = ventilationBoitier; Restart = "always"; RestartSec = 5; };
  };

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
    deadlock-mod-manager # mods pour Deadlock (Valve) : trouve le jeu dans Steam tout seul
  ];
}
