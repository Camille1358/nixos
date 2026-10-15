# Capteurs de la barre du haut (Waybar) : processeur, carte graphique, mémoire, températures.
# Appelé par desktop-home.nix avec un argument : cpu | gpu | ram | temp
# Chaque appel affiche une ligne JSON : texte de la barre, infobulle, et "classe" (pour la couleur).
#
# Les icônes sont passées par desktop-home.nix dans les variables ICONE_* (police Nerd Font).

NB_APPLIS=5 # nombre d'applications listées dans les infobulles

# (".firefox-wrapped" devient "firefox" : on retire les traces des enveloppes Nix)
# Rend un texte sûr pour l'infobulle (qui interprète < > & comme de la mise en forme)
echappe() { sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }


# Sortie JSON pour Waybar
sortie() { # $1 texte, $2 infobulle, $3 classe
  jq -cn --arg t "$1" --arg b "$2" --arg c "$3" '{text: $t, tooltip: $b, class: $c}'
}

# Couleur selon la température : $1 valeur, $2 tiède dès, $3 chaud dès, $4 critique dès
niveau() {
  if [ "$1" -ge "$4" ]; then echo critique
  elif [ "$1" -ge "$3" ]; then echo chaud
  elif [ "$1" -ge "$2" ]; then echo tiede
  else echo froid
  fi
}

# Carte graphique dédiée : celle qui a le plus de mémoire vidéo (la RX 6800 XT, pas la puce
# intégrée au processeur).
carte_gpu() {
  meilleure="" max=0
  for c in /sys/class/drm/card[0-9]*/device; do
    v=$(cat "$c/mem_info_vram_total" 2>/dev/null) || continue
    [ "$v" -gt "$max" ] && { max=$v; meilleure=$c; }
  done
  echo "$meilleure"
}

capteur_par_nom() { # dossier hwmon dont le nom est $1
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] && { echo "$h"; return; }
  done
}

case "$1" in
  cpu)
    # Deux mesures à 0,7 s d'intervalle : la seconde donne l'activité récente (la première est
    # une moyenne depuis le démarrage, trompeuse).
    mesure=$(LC_ALL=C top -b -c -n 2 -d 0.7 -w 512 | awk '/^top -/{n++} n==2')
    inactif=$(echo "$mesure" | awk -F',' '/^%Cpu/ { for (i=1;i<=NF;i++) if ($i ~ / id/) { gsub(/[^0-9.]/,"",$i); print $i } }')
    usage=$(awk -v i="${inactif:-100}" 'BEGIN { printf "%d", 100 - i + 0.5 }')
    coeurs=$(nproc)
    applis=$(echo "$mesure" | awk -v c="$coeurs" '
      /PID USER/ { liste = 1; next }
      liste && $9 + 0 > 0 { nom = $12; sub(/.*\//, "", nom); if (nom != "top") t[nom] += $9 / c } # nom = programme, sans son chemin
      END { for (n in t) printf "%.1f\t%s\n", t[n], n }' \
      | sort -rn | head -n "$NB_APPLIS" | awk -F'\t' '{ printf "%5.1f %%  %s\n", $1, $2 }')
    applis=$(echo "$applis" | sed -E 's/  \.([^ ]+)/  \1/; s/-wrapp?e?d?$//; s/[:]$//' | echappe)
    bulle="<b>Processeur : $usage %</b>
<tt>${applis:-  (rien de notable)}</tt>"
    sortie "$ICONE_CPU  $usage%" "$bulle" ""
    ;;

  ram)
    # Mémoire vive, puis mémoire vidéo : total utilisé, et les applications les plus gourmandes
    # avec leur part du total (colonne %).
    read -r total utilise < <(free -b | awk '/^Mem:/ { print $2, $3 }')
    pct=$(( utilise * 100 / total ))
    go() { awk -v o="$1" 'BEGIN { printf "%.1f", o / 1073741824 }'; }
    # $1 = total en Kio ; lignes "Kio<tab>nom" en entrée -> "taille  %  nom"
    tableau() {
      sort -rn | head -n "$NB_APPLIS" | awk -F'\t' -v tot="$1" '{
        m = $1 / 1024
        taille = (m >= 1024) ? sprintf("%5.1f Go", m / 1024) : sprintf("%5.0f Mo", m)
        nom = $2; sub(/^\./, "", nom); sub(/-wrapp?e?d?$/, "", nom); sub(/:$/, "", nom)
        printf "%s  %-16.16s %5.1f %%\n", taille, nom, $1 * 100 / tot }' \
        | echappe
    }

    applis=$(ps -eo rss=,args= | awk '{ k = $2; sub(/.*\//, "", k); t[k] += $1 }
      END { for (n in t) printf "%d\t%s\n", t[n], n }' | tableau $(( total / 1024 )))

    # Mémoire vidéo par application : chaque programme qui utilise la carte graphique y décrit
    # sa consommation dans /proc/<numéro>/fdinfo (seulement lisible pour tes propres programmes).
    c=$(carte_gpu)
    vu=$(cat "$c/mem_info_vram_used"); vt=$(cat "$c/mem_info_vram_total")
    carte=$(basename "$(readlink -f "$c")")
    vram=$(grep -s -H -E "^drm-(client-id|pdev|memory-vram):" /proc/[0-9]*/fdinfo/* 2>/dev/null \
      | awk -v carte="$carte" '{
          i = index($0, ":drm-"); chemin = substr($0, 1, i - 1); reste = substr($0, i + 1)
          j = index(reste, ":"); cle = substr(reste, 1, j - 1); val = substr(reste, j + 1)
          gsub(/^[ \t]+|[ \t]*KiB$/, "", val)
          split(chemin, morceau, "/"); pid = morceau[3]; fd = pid "/" morceau[5]
          if (cle == "drm-pdev") pdev[fd] = val
          else if (cle == "drm-client-id") client[fd] = val
          else vram[fd] = val }
        END {
          # un même client peut apparaître sur plusieurs descripteurs : on ne le compte qu une fois
          for (fd in client) if (pdev[fd] == carte) {
            split(fd, m, "/"); id = m[1] "/" client[fd]
            if (!(id in vu)) { vu[id] = 1; t[m[1]] += vram[fd] } }
          for (p in t) if (t[p] > 0) printf "%d\t%s\n", t[p], p }' \
      | while IFS=$'\t' read -r kio pid; do
          nom=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | awk '{ print $1 }' | sed 's|.*/||')
          printf '%s\t%s\n' "$kio" "${nom:-?}"
        done \
      | awk -F'\t' '{ t[$2] += $1 } END { for (n in t) printf "%d\t%s\n", t[n], n }' \
      | tableau $(( vt / 1024 )))

    bulle="<b>Mémoire : $(go "$utilise") Go / $(go "$total") Go</b>
<tt>$applis</tt>

<b>Mémoire vidéo : $(go "$vu") Go / $(go "$vt") Go</b>
<tt>${vram:-  (aucune application)}</tt>"
    sortie "$ICONE_RAM  $pct%" "$bulle" ""
    ;;

  gpu)
    c=$(carte_gpu)
    [ -n "$c" ] || { sortie "" "" ""; exit 0; }
    usage=$(cat "$c/gpu_busy_percent")
    vu=$(cat "$c/mem_info_vram_used"); vt=$(cat "$c/mem_info_vram_total")
    h=$(echo "$c"/hwmon/hwmon*)
    puissance=$(awk '{ printf "%d", $1 / 1000000 }' "$h/power1_average" 2>/dev/null || awk '{ printf "%d", $1 / 1000000 }' "$h/power1_input" 2>/dev/null)
    freq=$(awk '/\*/ { print $2 }' "$c/pp_dpm_sclk" 2>/dev/null)
    bulle="<b>Carte graphique : $usage %</b>
<tt>Mémoire vidéo  $(awk -v u="$vu" -v t="$vt" 'BEGIN { printf "%.1f Go / %.1f Go", u/1073741824, t/1073741824 }')
Consommation   ${puissance:-?} W
Fréquence      ${freq:-?}</tt>"
    sortie "$ICONE_GPU  $usage%" "$bulle" ""
    ;;

  temp)
    # Une seule température dans la barre : celle de la carte graphique (couleur selon la
    # chaleur). Survol : le détail de la carte graphique, et le processeur.
    c=$(carte_gpu); h=$(echo "$c"/hwmon/hwmon*)
    lire() { # température dont l'étiquette est $1 (edge, junction, mem)
      for f in "$h"/temp*_label; do
        [ "$(cat "$f")" = "$1" ] && { echo $(( $(cat "${f%_label}_input") / 1000 )); return; }
      done
    }
    bord=$(lire edge); point=$(lire junction); mem=$(lire mem)
    cpu=$(( $(cat "$(capteur_par_nom k10temp)/temp1_input") / 1000 ))
    bulle="<b>Carte graphique</b>
<tt>Température           ${bord:-?} °C
Point le plus chaud   ${point:-?} °C
Mémoire vidéo         ${mem:-?} °C</tt>

<b>Processeur</b>
<tt>Température           ${cpu} °C</tt>"
    sortie "$ICONE_TEMP  ${bord:-?}°C" "$bulle" "$(niveau "${bord:-0}" 65 80 90)"
    ;;
esac
