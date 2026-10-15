//! Modules de la barre du haut (Waybar) et petites commandes du bureau.
//!
//!   panneaux capteurs cpu|gpu|ram|temp   mesures : une ligne JSON (texte, infobulle, classe)
//!   panneaux notifs                      cloche des notifications
//!   panneaux etat                        témoin "veille auto désactivée" / "arrêt programmé"
//!   panneaux reduites-barre              témoin des fenêtres réduites
//!   panneaux volume up|down|mute         touches multimédia + petite notification
//!   panneaux veille-auto                 appelé par hypridle : met l'ordinateur en veille
//!   panneaux capture-ecran [ecran]       capture d'écran (zone, ou écran entier), puis l'aperçu
//!   panneaux lanceur                     lanceur d'applications (Rofi) + attrape-clic
//!
//! Ces commandes n'ouvrent aucune fenêtre : elles démarrent sans GTK, donc très vite (la barre
//! en lance toutes les quelques secondes).

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

use chrono::{Datelike, Local, TimeZone};
use serde_json::{Value, json};

use crate::outils::{dossier_etat, dossier_session, executer, lancer};
use crate::style::THEME;

// Icônes (police Nerd Font)
const ICONE_CPU: &str = "\u{f2db}";
const ICONE_GPU: &str = "\u{f02ae}";
const ICONE_RAM: &str = "\u{f035b}";
const ICONE_TEMP: &str = "\u{f2c9}";
const ICONE_CAFE: &str = "\u{f0f4}";
const ICONE_SABLIER: &str = "\u{f253}";
const ICONE_FENETRE: &str = "\u{f2d0}";
const CLOCHE: &str = "\u{f009a}";
const CLOCHE_SONNE: &str = "\u{f009e}";
const CLOCHE_BARREE: &str = "\u{f009b}";

const NB_APPLIS: usize = 5; // applications listées dans les infobulles
const BATTEMENTS: f64 = 100.0; // battements du noyau par seconde (USER_HZ, 100 sous Linux)

/// Lance la commande demandée et renvoie son code de sortie ; None = pas une de ces commandes.
pub fn commande(arguments: &[String]) -> Option<i32> {
    let argument = |i: usize| arguments.get(i).map_or("", String::as_str);
    match argument(1) {
        "capteurs" => capteurs(argument(2)),
        "notifs" => notifs(),
        "etat" => etat(),
        "reduites-barre" => reduites_barre(),
        "volume" => volume(argument(2)),
        "veille-auto" => veille_auto(),
        "capture-ecran" => capture(argument(2) == "ecran"),
        "lanceur" => lanceur(),
        "defilement" => crate::defilement::lancer(),
        _ => return None,
    }
    Some(0)
}

fn sortie(texte: &str, infobulle: &str, classe: Value) {
    println!("{}", json!({ "text": texte, "tooltip": infobulle, "class": classe }));
}

/// Texte sûr pour l'infobulle (qui interprète < > & comme de la mise en forme)
fn echappe(texte: &str) -> String {
    texte.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn lire(chemin: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(chemin).ok().map(|t| t.trim().to_owned())
}

fn lire_nombre(chemin: impl AsRef<Path>) -> Option<u64> {
    lire(chemin)?.parse().ok()
}

fn go(octets: u64) -> String {
    format!("{:.1}", octets as f64 / 1_073_741_824.0)
}

// =============================================================================
// Processus
// =============================================================================
/// Nom d'un programme, sans son chemin ni les traces des enveloppes Nix
/// (".firefox-wrapped" devient "firefox").
fn nom_propre(brut: &str) -> String {
    let nom = brut.rsplit('/').next().unwrap_or(brut);
    let nom = nom.strip_prefix('.').unwrap_or(nom);
    let nom = nom.strip_suffix("-wrapped").unwrap_or(nom);
    nom.strip_suffix(':').unwrap_or(nom).to_owned()
}

/// Nom du programme d'un processus : le premier mot de sa commande (son nom court pour le noyau).
fn nom_du_processus(pid: u32) -> Option<String> {
    let commande = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    match commande.split(|&o| o == 0).next().filter(|m| !m.is_empty()) {
        Some(mot) => Some(nom_propre(&String::from_utf8_lossy(mot))),
        None => lire(format!("/proc/{pid}/comm")).map(|n| nom_propre(&n)),
    }
}

fn pids() -> Vec<u32> {
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .collect()
}

/// Temps de calcul de chaque processus, en battements du noyau.
fn temps_processeur() -> HashMap<u32, u64> {
    let mut resultat = HashMap::new();
    for pid in pids() {
        let Some(stat) = lire(format!("/proc/{pid}/stat")) else { continue };
        // Le nom (entre parenthèses) peut contenir des espaces : on repart après la dernière ")"
        let Some(fin) = stat.rfind(')') else { continue };
        let champs: Vec<u64> =
            stat[fin + 1..].split_whitespace().skip(11).take(2).filter_map(|c| c.parse().ok()).collect();
        if let [utilisateur, systeme] = champs[..] {
            resultat.insert(pid, utilisateur + systeme);
        }
    }
    resultat
}

/// (total, inactif) du processeur depuis le démarrage, en battements du noyau.
fn stat_globale() -> (u64, u64) {
    let texte = lire("/proc/stat").unwrap_or_default();
    let champs: Vec<u64> = texte
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .skip(1)
        .filter_map(|c| c.parse().ok())
        .collect();
    (champs.iter().take(8).sum(), champs.get(3).copied().unwrap_or(0))
}

/// Lignes "taille  nom  %" des plus gros. `elements` : nom -> Kio.
fn tableau(elements: HashMap<String, u64>, total_kio: u64) -> String {
    let mut liste: Vec<(String, u64)> = elements.into_iter().collect();
    liste.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let mut texte = String::new();
    for (nom, kio) in liste.into_iter().take(NB_APPLIS) {
        let mo = kio as f64 / 1024.0;
        let taille = if mo >= 1024.0 { format!("{:5.1} Go", mo / 1024.0) } else { format!("{mo:5.0} Mo") };
        let pct = kio as f64 * 100.0 / total_kio.max(1) as f64;
        let _ = writeln!(texte, "{taille}  {nom:<16.16} {pct:5.1} %");
    }
    echappe(texte.trim_end())
}

// =============================================================================
// Carte graphique
// =============================================================================
/// Carte graphique dédiée : celle qui a le plus de mémoire vidéo (la RX 6800 XT, pas la puce
/// intégrée au processeur).
fn carte_gpu() -> Option<PathBuf> {
    let mut meilleure = None;
    let mut max = 0;
    for entree in fs::read_dir("/sys/class/drm").ok()?.flatten() {
        let nom = entree.file_name().to_string_lossy().into_owned();
        let Some(numero) = nom.strip_prefix("card") else { continue };
        if numero.is_empty() || !numero.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let appareil = entree.path().join("device");
        if let Some(v) = lire_nombre(appareil.join("mem_info_vram_total"))
            && v > max
        {
            max = v;
            meilleure = Some(appareil);
        }
    }
    meilleure
}

fn premier_hwmon(dossier: &Path) -> Option<PathBuf> {
    fs::read_dir(dossier.join("hwmon")).ok()?.flatten().map(|e| e.path()).min()
}

fn capteur_par_nom(nom: &str) -> Option<PathBuf> {
    fs::read_dir("/sys/class/hwmon")
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|h| lire(h.join("name")).as_deref() == Some(nom))
}

/// Mémoire vidéo par application : chaque programme qui utilise la carte graphique décrit sa
/// consommation dans /proc/<numéro>/fdinfo (seulement lisible pour tes propres programmes).
fn vram_par_appli(carte: &Path) -> HashMap<String, u64> {
    let identifiant = fs::canonicalize(carte)
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let mut par_nom: HashMap<String, u64> = HashMap::new();
    for pid in pids() {
        let Ok(descripteurs) = fs::read_dir(format!("/proc/{pid}/fdinfo")) else { continue };
        let mut vus = HashSet::new(); // un même client peut apparaître sur plusieurs descripteurs
        let mut total = 0;
        for d in descripteurs.flatten() {
            let Some(texte) = lire(d.path()) else { continue };
            let (mut pdev, mut client, mut vram) = (None, None, 0);
            for ligne in texte.lines() {
                if let Some(v) = ligne.strip_prefix("drm-pdev:") {
                    pdev = Some(v.trim().to_owned());
                } else if let Some(v) = ligne.strip_prefix("drm-client-id:") {
                    client = Some(v.trim().to_owned());
                } else if let Some(v) = ligne.strip_prefix("drm-memory-vram:") {
                    vram = v.trim().trim_end_matches("KiB").trim().parse().unwrap_or(0);
                }
            }
            if pdev.as_deref() == Some(identifiant.as_str())
                && let Some(client) = client
                && vus.insert(client)
            {
                total += vram;
            }
        }
        if total > 0
            && let Some(nom) = nom_du_processus(pid)
        {
            *par_nom.entry(nom).or_default() += total;
        }
    }
    par_nom
}

// =============================================================================
// Capteurs
// =============================================================================
fn capteurs(mode: &str) {
    match mode {
        "cpu" => capteur_cpu(),
        "ram" => capteur_ram(),
        "gpu" => capteur_gpu(),
        "temp" => capteur_temp(),
        _ => eprintln!("usage : panneaux capteurs cpu|gpu|ram|temp"),
    }
}

fn capteur_cpu() {
    // Deux mesures à 0,7 s d'intervalle : la seconde donne l'activité récente (la première est
    // une moyenne depuis le démarrage, trompeuse).
    let (avant_total, avant_inactif) = stat_globale();
    let avant = temps_processeur();
    sleep(Duration::from_millis(700));
    let (apres_total, apres_inactif) = stat_globale();
    let apres = temps_processeur();

    let total = apres_total.saturating_sub(avant_total).max(1) as f64;
    let inactif = apres_inactif.saturating_sub(avant_inactif) as f64;
    let usage = (100.0 - inactif * 100.0 / total + 0.5).clamp(0.0, 100.0) as i64;

    // Part de chaque programme dans la puissance totale (tous cœurs confondus)
    let coeurs = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
    let mut par_nom: HashMap<String, f64> = HashMap::new();
    for (pid, fin) in &apres {
        let battements = fin.saturating_sub(avant.get(pid).copied().unwrap_or(*fin)) as f64;
        if battements > 0.0
            && let Some(nom) = nom_du_processus(*pid)
        {
            *par_nom.entry(nom).or_default() += battements / (BATTEMENTS * 0.7) * 100.0 / coeurs;
        }
    }
    par_nom.remove("panneaux"); // (soi-même)
    let mut liste: Vec<(String, f64)> = par_nom.into_iter().collect();
    liste.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let mut applis = String::new();
    for (nom, pct) in liste.into_iter().take(NB_APPLIS) {
        let _ = writeln!(applis, "{pct:5.1} %  {nom}");
    }
    let applis =
        if applis.is_empty() { "  (rien de notable)".to_owned() } else { echappe(applis.trim_end()) };
    let bulle = format!("<b>Processeur : {usage} %</b>\n<tt>{applis}</tt>");
    sortie(&format!("{ICONE_CPU}  {usage}%"), &bulle, json!(""));
}

fn capteur_ram() {
    // Mémoire vive, puis mémoire vidéo : total utilisé, et les applications les plus gourmandes
    // avec leur part du total (colonne %).
    let infos = lire("/proc/meminfo").unwrap_or_default();
    let kio = |cle: &str| -> u64 {
        infos
            .lines()
            .find_map(|l| l.strip_prefix(cle)?.trim().trim_end_matches("kB").trim().parse().ok())
            .unwrap_or(0)
    };
    let total = kio("MemTotal:") * 1024;
    let utilise = total.saturating_sub(kio("MemAvailable:") * 1024);
    let pct = utilise * 100 / total.max(1);

    let mut par_nom: HashMap<String, u64> = HashMap::new();
    for pid in pids() {
        // statm : 2e champ = pages présentes en mémoire vive (4 Kio)
        let pages: u64 = lire(format!("/proc/{pid}/statm"))
            .and_then(|s| s.split_whitespace().nth(1)?.parse().ok())
            .unwrap_or(0);
        if pages > 0
            && let Some(nom) = nom_du_processus(pid)
        {
            *par_nom.entry(nom).or_default() += pages * 4;
        }
    }
    let applis = tableau(par_nom, total / 1024);

    let (mut vu, mut vt, mut vram) = (0, 0, String::new());
    if let Some(carte) = carte_gpu() {
        vu = lire_nombre(carte.join("mem_info_vram_used")).unwrap_or(0);
        vt = lire_nombre(carte.join("mem_info_vram_total")).unwrap_or(0);
        vram = tableau(vram_par_appli(&carte), vt / 1024);
    }
    if vram.is_empty() {
        vram = "  (aucune application)".to_owned();
    }
    let bulle = format!(
        "<b>Mémoire : {} Go / {} Go</b>\n<tt>{applis}</tt>\n\n<b>Mémoire vidéo : {} Go / {} Go</b>\n<tt>{vram}</tt>",
        go(utilise),
        go(total),
        go(vu),
        go(vt)
    );
    sortie(&format!("{ICONE_RAM}  {pct}%"), &bulle, json!(""));
}

fn capteur_gpu() {
    let Some(carte) = carte_gpu() else {
        sortie("", "", json!(""));
        return;
    };
    let usage = lire_nombre(carte.join("gpu_busy_percent")).unwrap_or(0);
    let vu = lire_nombre(carte.join("mem_info_vram_used")).unwrap_or(0);
    let vt = lire_nombre(carte.join("mem_info_vram_total")).unwrap_or(0);
    let puissance = premier_hwmon(&carte)
        .and_then(|h| lire_nombre(h.join("power1_average")).or_else(|| lire_nombre(h.join("power1_input"))))
        .map_or("?".to_owned(), |p| (p / 1_000_000).to_string());
    let frequence = lire(carte.join("pp_dpm_sclk"))
        .and_then(|t| t.lines().find(|l| l.contains('*'))?.split_whitespace().nth(1).map(str::to_owned))
        .unwrap_or_else(|| "?".to_owned());
    let bulle = format!(
        "<b>Carte graphique : {usage} %</b>\n<tt>Mémoire vidéo  {} Go / {} Go\nConsommation   {puissance} W\nFréquence      {frequence}</tt>",
        go(vu),
        go(vt)
    );
    sortie(&format!("{ICONE_GPU}  {usage}%"), &bulle, json!(""));
}

/// Couleur selon la température.
fn niveau(valeur: i64) -> &'static str {
    match valeur {
        v if v >= 90 => "critique",
        v if v >= 80 => "chaud",
        v if v >= 65 => "tiede",
        _ => "froid",
    }
}

fn capteur_temp() {
    // Une seule température dans la barre : celle de la carte graphique (couleur selon la
    // chaleur). Survol : le détail de la carte graphique, et le processeur.
    let hwmon = carte_gpu().and_then(|c| premier_hwmon(&c));
    let par_etiquette = |etiquette: &str| -> Option<i64> {
        let hwmon = hwmon.as_ref()?;
        fs::read_dir(hwmon).ok()?.flatten().find_map(|entree| {
            let nom = entree.file_name().to_string_lossy().into_owned();
            if nom.starts_with("temp") && nom.ends_with("_label") && lire(entree.path())? == etiquette {
                Some(lire_nombre(hwmon.join(nom.replace("_label", "_input")))? as i64 / 1000)
            } else {
                None
            }
        })
    };
    let (bord, point, mem) = (par_etiquette("edge"), par_etiquette("junction"), par_etiquette("mem"));
    let texte = |t: Option<i64>| t.map_or("?".to_owned(), |t| t.to_string());
    let cpu = texte(
        capteur_par_nom("k10temp").and_then(|h| lire_nombre(h.join("temp1_input"))).map(|t| t as i64 / 1000),
    );
    let bulle = format!(
        "<b>Carte graphique</b>\n<tt>Température           {} °C\nPoint le plus chaud   {} °C\nMémoire vidéo         {} °C</tt>\n\n<b>Processeur</b>\n<tt>Température           {cpu} °C</tt>",
        texte(bord),
        texte(point),
        texte(mem)
    );
    sortie(&format!("{ICONE_TEMP}  {}°C", texte(bord)), &bulle, json!(niveau(bord.unwrap_or(0))));
}

// =============================================================================
// Cloche des notifications
// =============================================================================
fn echappe_html(texte: &str) -> String {
    echappe(texte).replace('"', "&quot;").replace('\'', "&#39;")
}

/// Simple cloche ; cloche qui sonne s'il y a des notifications arrivées depuis la dernière
/// ouverture du panneau ; cloche barrée en "Ne pas déranger". Survol : seulement les dernières
/// notifications, groupées par application, avec l'heure (les non lues marquées d'un point).
fn notifs() {
    let dossier = dossier_etat().join("notifications");
    let vu: i64 = lire(dossier.join("vu")).and_then(|t| t.parse().ok()).unwrap_or(0);
    let mut toutes: Vec<Value> = lire(dossier.join("journal.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let temps = |n: &Value| n["t"].as_i64().unwrap_or(0);
    let nouvelles = toutes.iter().filter(|n| temps(n) > vu).count();

    // Les plus récentes, groupées par application (la plus récente d'abord)
    toutes.sort_by_key(|n| std::cmp::Reverse(temps(n)));
    toutes.truncate(THEME.notifs_survol);
    let mut groupes: Vec<(&str, Vec<&Value>)> = Vec::new();
    for n in &toutes {
        let appli = n["app"].as_str().unwrap_or_default();
        match groupes.iter_mut().find(|(a, _)| *a == appli) {
            Some((_, liste)) => liste.push(n),
            None => groupes.push((appli, vec![n])),
        }
    }
    let (cyan, discret) = (THEME.couleur("cyan"), THEME.couleur("muted"));
    let aujourdhui = Local::now().date_naive();
    let mut blocs = Vec::new();
    for (appli, liste) in groupes {
        let mut bloc = format!("<b>{}</b>", echappe_html(appli));
        for n in liste {
            let date = Local.timestamp_opt(temps(n), 0).single().unwrap_or_default();
            let heure = if date.date_naive() == aujourdhui {
                date.format("%H:%M").to_string()
            } else {
                date.format("%d/%m %H:%M").to_string()
            };
            let point =
                if temps(n) > vu { format!("<span color=\"#{cyan}\">●</span>") } else { " ".to_owned() };
            let titre = echappe_html(n["titre"].as_str().unwrap_or_default());
            let _ = write!(bloc, "\n{point} <span color=\"#{discret}\">{heure}</span>  {titre}");
            let corps =
                n["texte"].as_str().unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" ");
            if !corps.is_empty() {
                let court = if corps.chars().count() > 70 {
                    corps.chars().take(69).collect::<String>() + "…"
                } else {
                    corps
                };
                let _ = write!(bloc, "\n         <span color=\"#{discret}\">{}</span>", echappe_html(&court));
            }
        }
        blocs.push(bloc);
    }
    let infobulle = if blocs.is_empty() { "Aucune notification".to_owned() } else { blocs.join("\n\n") };

    let dnd = executer(&["makoctl", "mode"]).1.split_whitespace().any(|m| m == "do-not-disturb");
    let (icone, classes) = if dnd {
        (CLOCHE_BARREE, json!(["dnd"]))
    } else if nouvelles > 0 {
        (CLOCHE_SONNE, if THEME.cloche_animee { json!(["nonlues", "animee"]) } else { json!(["nonlues"]) })
    } else {
        (CLOCHE, json!([]))
    };
    sortie(icone, &infobulle, classes);
}

// =============================================================================
// Témoins
// =============================================================================
const JOURS: [&str; 7] = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"];
const MOIS: [&str; 12] = [
    "janvier",
    "février",
    "mars",
    "avril",
    "mai",
    "juin",
    "juillet",
    "août",
    "septembre",
    "octobre",
    "novembre",
    "décembre",
];

/// Témoin : n'apparaît que si la veille auto est désactivée (tasse de café) ou si un arrêt est
/// programmé (sablier + heure).
fn etat() {
    let (mut texte, mut bulle) = (String::new(), String::new());
    if crate::session::drapeau().exists() {
        texte.push_str(ICONE_CAFE);
        bulle.push_str("Veille automatique de l'ordinateur désactivée");
    }
    if let Some(prevu) = crate::session::arret_prevu() {
        if !texte.is_empty() {
            texte.push_str("  ");
            bulle.push('\n');
        }
        let _ = write!(texte, "{ICONE_SABLIER} {}", prevu.format("%H:%M"));
        let _ = write!(
            bulle,
            "Arrêt programmé : {} {} {} à {}",
            JOURS[prevu.weekday().num_days_from_monday() as usize],
            prevu.format("%d"),
            MOIS[prevu.month0() as usize],
            prevu.format("%H:%M")
        );
    }
    println!("{}", json!({ "text": texte, "tooltip": bulle }));
}

/// Témoin des fenêtres réduites (invisible s'il n'y en a aucune).
fn reduites_barre() {
    let fenetres = crate::reduites::fenetres_reduites();
    if fenetres.is_empty() {
        println!("{}", json!({ "text": "" }));
        return;
    }
    let titres: Vec<&str> = fenetres.iter().map(|f| f["title"].as_str().unwrap_or_default()).collect();
    println!(
        "{}",
        json!({ "text": format!("{ICONE_FENETRE}  {}", fenetres.len()), "tooltip": titres.join("\n") })
    );
}

// =============================================================================
// Commandes du bureau
// =============================================================================
/// Volume (touches multimédia) + petite notification avec jauge.
fn volume(action: &str) {
    match action {
        "up" => drop(executer(&["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+"])),
        "down" => drop(executer(&["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"])),
        "mute" => drop(executer(&["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])),
        _ => {}
    }
    // Réponse de la forme "Volume: 0.45" ou "Volume: 0.45 [MUTED]"
    let etat = executer(&["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]).1;
    let pct = etat
        .split_whitespace()
        .nth(1)
        .and_then(|v| v.parse::<f64>().ok())
        .map_or(0, |v| (v * 100.0).round() as i64);
    let titre = if etat.contains("MUTED") { "Son coupé".to_owned() } else { format!("Volume {pct} %") };
    let jauge = format!("int:value:{pct}");
    lancer(&[
        "notify-send",
        "-a",
        "volume",
        "-t",
        "1200",
        "-h",
        "string:x-canonical-private-synchronous:volume",
        "-h",
        &jauge,
        &titre,
    ]);
}

/// Appelé par hypridle après "ordiEnVeilleApres" minutes d'inactivité. Pas de veille tant que
/// la veille auto est désactivée, ni pendant que la boucle de nuit de l'IA travaille.
fn veille_auto() {
    if crate::session::drapeau().exists()
        || executer(&["systemctl", "is-active", "--quiet", "ia-nuit.service"]).0
    {
        return;
    }
    lancer(&["systemctl", "suspend"]);
}

/// Capture d'écran façon ShareX. L'écran où se trouve la souris est photographié à l'instant
/// même (tout est figé, sans le curseur), puis :
///   - zone : on choisit la zone sur cette photo, avec une loupe au pixel près (selection.rs) ;
///   - écran entier : l'aperçu s'ouvre directement.
///
/// L'aperçu propose Copier, Enregistrer, Enregistrer sous…, Texte (OCR) ou Annuler.
/// L'image attend en mémoire vive : copiée ou annulée, elle ne laisse aucune trace.
fn capture(ecran_entier: bool) {
    let ecran = crate::outils::hyprland("monitors")
        .as_array()
        .and_then(|m| {
            m.iter().find(|m| m["focused"] == true).and_then(|m| m["name"].as_str().map(str::to_owned))
        })
        .unwrap_or_default();
    let nanos = Local::now().timestamp_nanos_opt().unwrap_or(0);
    let fichier = dossier_session().join(format!("capture-{nanos}.png")).to_string_lossy().into_owned();
    // -l 1 : compression légère, l'image est prête plus vite (elle ne reste pas sur le disque)
    let mut photo = Command::new("grim");
    photo.args(["-l", "1"]);
    if !ecran.is_empty() {
        photo.args(["-o", &ecran]);
    }
    if !photo.arg(&fichier).status().is_ok_and(|s| s.success()) {
        return;
    }
    if let Ok(moi) = std::env::current_exe() {
        let mut suite = Command::new(moi);
        if ecran_entier {
            suite.args(["apercu", &fichier]);
        } else {
            suite.args(["selection", &fichier, &ecran]);
        }
        let _ = suite.exec();
    }
}

/// Lanceur d'applications (Rofi). Relancer la commande le referme ; un clic n'importe où
/// ailleurs aussi, grâce à l'"attrape-clic" posé sous lui (attrape.rs).
fn lanceur() {
    if executer(&["pgrep", "-x", "rofi"]).0 {
        lancer(&["pkill", "-x", "rofi"]);
        return;
    }
    let attrape = std::env::current_exe().ok().and_then(|moi| Command::new(moi).arg("attrape").spawn().ok());
    let _ = Command::new("rofi").args(["-show", "drun"]).status();
    if let Some(mut attrape) = attrape {
        let _ = attrape.kill();
        let _ = attrape.wait();
    }
}

#[cfg(test)]
mod essais {
    use super::*;

    #[test]
    fn noms() {
        assert_eq!(nom_propre("/nix/store/x-firefox/bin/.firefox-wrapped"), "firefox");
        assert_eq!(nom_propre("kworker:"), "kworker");
        assert_eq!(nom_propre("code"), "code");
    }

    #[test]
    fn niveaux() {
        assert_eq!(niveau(40), "froid");
        assert_eq!(niveau(70), "tiede");
        assert_eq!(niveau(85), "chaud");
        assert_eq!(niveau(95), "critique");
    }

    #[test]
    fn tableau_formate() {
        let mut e = HashMap::new();
        e.insert("firefox".to_owned(), 2 * 1024 * 1024);
        e.insert("a<b".to_owned(), 512 * 1024);
        let t = tableau(e, 8 * 1024 * 1024);
        assert_eq!(t, "  2.0 Go  firefox           25.0 %\n  512 Mo  a&lt;b                6.2 %");
    }
}
