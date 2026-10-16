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
//! Ces commandes n'ouvrent aucune fenêtre. La barre les lance toutes les quelques secondes,
//! par "panneaux-barre" : le même code dans un programme sans GTK (barre_seule.rs), qui
//! démarre en quelques millisecondes au lieu de charger toutes les bibliothèques graphiques.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

use chrono::{Datelike, Local, TimeZone};
use serde_json::{Value, json};

use crate::style::THEME;
use crate::systeme::{
    arret_prevu, dossier_etat, dossier_session, drapeau_veille, executer, fenetres_reduites, hyprland, lancer,
    programme_panneaux,
};

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

fn sortie(texte: &str, infobulle: &str, classe: &str) {
    println!("{}", json!({ "text": texte, "tooltip": infobulle, "class": classe }));
}

/// Âge d'un fichier (depuis sa dernière écriture), ou None s'il n'existe pas.
fn age(fichier: &Path) -> Option<Duration> {
    fs::metadata(fichier).ok()?.modified().ok()?.elapsed().ok()
}

/// Écrit un fichier d'un coup (à côté, puis renommé) : il n'est jamais lu à moitié écrit.
fn ecrire_d_un_coup(fichier: &Path, texte: &str) {
    let provisoire = fichier.with_extension("tmp");
    if fs::write(&provisoire, texte).is_ok() {
        let _ = fs::rename(provisoire, fichier);
    }
}

/// Texte sûr pour l'infobulle (qui interprète < > & comme de la mise en forme)
fn echappe(texte: &str) -> String {
    texte.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn lire(chemin: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(chemin).ok().map(|t| t.trim().to_owned())
}

/// Lecteur des petits fichiers du noyau (/proc, /sys), avec un tampon réutilisé d'un fichier à
/// l'autre. Le noyau fabrique ces fichiers d'un coup quand on les lit : une seule lecture
/// suffit. (`fs::read_to_string` demande d'abord leur taille, toujours 0 ici, puis lit par
/// morceaux croissants : six appels au système par fichier, sur des centaines de fichiers à
/// chaque mesure.)
struct Lecteur {
    tampon: Vec<u8>,
}

impl Lecteur {
    fn new() -> Self {
        Self { tampon: vec![0; 16 * 1024] }
    }

    /// Contenu brut du fichier.
    fn octets(&mut self, chemin: impl AsRef<Path>) -> Option<&[u8]> {
        let mut fichier = fs::File::open(chemin).ok()?;
        let mut longueur = 0;
        loop {
            let lus = fichier.read(&mut self.tampon[longueur..]).ok()?;
            longueur += lus;
            if lus == 0 || longueur < self.tampon.len() {
                break; // tampon pas rempli : le fichier est fini
            }
            let taille = self.tampon.len();
            self.tampon.resize(taille * 2, 0); // fichier plus grand que le tampon (rare)
        }
        Some(&self.tampon[..longueur])
    }

    /// Contenu en texte (None s'il n'est pas en UTF-8).
    fn texte(&mut self, chemin: impl AsRef<Path>) -> Option<&str> {
        std::str::from_utf8(self.octets(chemin)?).ok()
    }
}

/// Détail qui change lentement mais coûte cher à mesurer (la mémoire de chaque application) :
/// refait au plus toutes les 15 s. Entre-temps, la barre (qui demande toutes les 3 s) reprend
/// le précédent, gardé en mémoire vive dans le fichier `nom`.
fn detail_garde(nom: &str, calcul: impl FnOnce() -> String) -> String {
    let fichier = dossier_session().join(nom);
    if age(&fichier).is_some_and(|age| age < Duration::from_secs(15))
        && let Ok(texte) = fs::read_to_string(&fichier)
    {
        return texte;
    }
    let texte = calcul();
    ecrire_d_un_coup(&fichier, &texte);
    texte
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

/// Nom du programme d'un processus (son nom court pour le noyau s'il n'a pas de commande).
fn nom_du_processus(pid: u32, lecteur: &mut Lecteur) -> Option<String> {
    let nom = lecteur
        .octets(format!("/proc/{pid}/cmdline"))
        .and_then(|commande| nom_de_commande(&String::from_utf8_lossy(commande)));
    nom.or_else(|| lecteur.texte(format!("/proc/{pid}/comm")).map(|n| nom_propre(n.trim())))
}

/// Nom lisible d'après une commande (mots séparés par des caractères nuls, comme dans /proc).
fn nom_de_commande(commande: &str) -> Option<String> {
    let mut mots: Vec<&str> = commande.split('\0').filter(|m| !m.is_empty()).collect();
    if let [titre] = mots[..]
        && titre.contains(' ')
    {
        // Programme qui a réécrit son titre (Electron, Firefox) : tout est dans le premier mot
        mots = titre.split(' ').filter(|m| !m.is_empty()).collect();
    }
    let (programme, arguments) = mots.split_first()?;
    if *programme == "/proc/self/exe" {
        return None; // relancé par lui-même (VS Code…) : son nom court pour le noyau est le bon
    }
    let programme = nom_propre(programme);
    // Un interpréteur fait tourner un script : son nom ("opensnitch-ui" plutôt que "python3.13")
    let interprete = ["python", "perl", "ruby", "node"].iter().any(|i| {
        programme.strip_prefix(i).is_some_and(|version| version.chars().all(|c| c.is_ascii_digit() || c == '.'))
    });
    if interprete && let Some(script) = arguments.iter().find(|a| !a.starts_with('-')) {
        return Some(nom_propre(script));
    }
    // Electron fait tourner une application : son dossier de données (~/.config/equibop-ptb),
    // sinon le dossier où elle est installée (…/Equibop/resources/app.asar)
    if programme == "electron" {
        for a in arguments {
            if let Some(appli) = a
                .strip_prefix("--user-data-dir=")
                .and_then(|d| d.split("/.config/").nth(1)?.split('/').next())
                .or_else(|| a.strip_suffix("/resources/app.asar")?.rsplit('/').next())
            {
                return Some(appli.to_lowercase());
            }
        }
    }
    Some(programme)
}

fn pids() -> Vec<u32> {
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .collect()
}

/// Une mesure du processeur depuis le démarrage, en battements du noyau : le total et le temps
/// inactif (tous cœurs confondus), et le temps de calcul de chaque processus.
#[derive(Debug, PartialEq)]
struct Mesure {
    total: u64,
    inactif: u64,
    par_pid: HashMap<u32, u64>,
}

impl Mesure {
    fn prendre(lecteur: &mut Lecteur) -> Self {
        let champs: Vec<u64> = lecteur
            .texte("/proc/stat")
            .and_then(|t| t.lines().next())
            .unwrap_or("")
            .split_ascii_whitespace()
            .skip(1)
            .filter_map(|c| c.parse().ok())
            .collect();
        let (total, inactif) = (champs.iter().take(8).sum(), champs.get(3).copied().unwrap_or(0));
        let mut par_pid = HashMap::new();
        for pid in pids() {
            let Some(stat) = lecteur.octets(format!("/proc/{pid}/stat")) else { continue };
            // Le nom (entre parenthèses) peut contenir des espaces, ou des octets qui ne sont pas
            // du texte : on repart après la dernière ")", où il n'y a plus que des nombres
            let Some(fin) = stat.iter().rposition(|&o| o == b')') else { continue };
            let Ok(nombres) = std::str::from_utf8(&stat[fin + 1..]) else { continue };
            let mut temps = nombres.split_ascii_whitespace().skip(11).filter_map(|c| c.parse::<u64>().ok());
            if let (Some(utilisateur), Some(systeme)) = (temps.next(), temps.next()) {
                par_pid.insert(pid, utilisateur + systeme);
            }
        }
        Self { total, inactif, par_pid }
    }

    /// Forme écrite, gardée entre deux appels : "total inactif", puis "processus temps" par ligne.
    fn ecrire(&self) -> String {
        let mut texte = format!("{} {}\n", self.total, self.inactif);
        for (pid, temps) in &self.par_pid {
            let _ = writeln!(texte, "{pid} {temps}");
        }
        texte
    }

    fn lire(texte: &str) -> Option<Self> {
        let mut lignes = texte.lines();
        let (total, inactif) = lignes.next()?.split_once(' ')?;
        let par_pid = lignes
            .filter_map(|l| {
                let (pid, temps) = l.split_once(' ')?;
                Some((pid.parse().ok()?, temps.parse().ok()?))
            })
            .collect();
        Some(Mesure { total: total.parse().ok()?, inactif: inactif.parse().ok()?, par_pid })
    }
}

/// La mesure précédente, gardée en mémoire vive entre deux appels de la barre (toutes les 3 s) :
/// l'activité est calculée sur tout l'intervalle écoulé, sans avoir à attendre.
fn mesure_precedente() -> Option<Mesure> {
    let fichier = dossier_session().join("panneaux-cpu");
    if age(&fichier)? > Duration::from_secs(30) {
        return None; // trop ancienne (la barre vient de démarrer) : sans intérêt
    }
    Mesure::lire(&fs::read_to_string(fichier).ok()?)
}

fn garder_mesure(mesure: &Mesure) {
    ecrire_d_un_coup(&dossier_session().join("panneaux-cpu"), &mesure.ecrire());
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

/// Mémoire vive par application, en Kio.
fn ram_par_appli() -> HashMap<String, u64> {
    let mut lecteur = Lecteur::new();
    let mut par_nom: HashMap<String, u64> = HashMap::new();
    for pid in pids() {
        // statm : 2e champ = pages présentes en mémoire vive (4 Kio)
        let pages: u64 = lecteur
            .texte(format!("/proc/{pid}/statm"))
            .and_then(|s| s.split_ascii_whitespace().nth(1)?.parse().ok())
            .unwrap_or(0);
        if pages > 0
            && let Some(nom) = nom_du_processus(pid, &mut lecteur)
        {
            *par_nom.entry(nom).or_default() += pages * 4;
        }
    }
    par_nom
}

/// Mémoire vidéo par application : chaque programme qui utilise la carte graphique décrit sa
/// consommation dans /proc/<numéro>/fdinfo (seulement lisible pour tes propres programmes).
fn vram_par_appli(carte: &Path) -> HashMap<String, u64> {
    let identifiant = fs::canonicalize(carte)
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let mut lecteur = Lecteur::new();
    let mut par_nom: HashMap<String, u64> = HashMap::new();
    for pid in pids() {
        let Ok(descripteurs) = fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
        let mut vus = HashSet::new(); // un même client peut apparaître sur plusieurs descripteurs
        let mut total = 0;
        for d in descripteurs.flatten() {
            // Seulement les fichiers ouverts sur une carte graphique (/dev/dri/...) : lire le
            // détail de tous les autres (des milliers, sur tout le système) coûterait pour rien.
            if !fs::read_link(d.path()).is_ok_and(|cible| cible.starts_with("/dev/dri")) {
                continue;
            }
            let Some(texte) = lecteur.texte(format!("/proc/{pid}/fdinfo/{}", d.file_name().to_string_lossy()))
            else {
                continue;
            };
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
            && let Some(nom) = nom_du_processus(pid, &mut lecteur)
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
    // L'activité depuis la mesure précédente (la moyenne depuis le démarrage serait trompeuse).
    // Premier appel : deux mesures à 0,3 s d'intervalle.
    let mut lecteur = Lecteur::new();
    let avant = mesure_precedente().unwrap_or_else(|| {
        let mesure = Mesure::prendre(&mut lecteur);
        sleep(Duration::from_millis(300));
        mesure
    });
    let apres = Mesure::prendre(&mut lecteur);
    garder_mesure(&apres);

    let total = apres.total.saturating_sub(avant.total).max(1) as f64;
    let inactif = apres.inactif.saturating_sub(avant.inactif) as f64;
    let usage = (100.0 - inactif * 100.0 / total + 0.5).clamp(0.0, 100.0) as i64;

    // Part de chaque programme dans la puissance totale (tous cœurs confondus) ; un programme
    // apparu entre les deux mesures n'a pas encore de mesure de départ : il attend la suivante.
    let mut par_nom: HashMap<String, f64> = HashMap::new();
    for (pid, fin) in &apres.par_pid {
        let Some(debut) = avant.par_pid.get(pid) else { continue };
        let battements = fin.saturating_sub(*debut) as f64;
        if battements > 0.0
            && let Some(nom) = nom_du_processus(*pid, &mut lecteur)
        {
            *par_nom.entry(nom).or_default() += battements * 100.0 / total;
        }
    }
    let mut liste: Vec<(String, f64)> = par_nom.into_iter().collect();
    liste.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let mut applis = String::new();
    for (nom, pct) in liste.into_iter().take(NB_APPLIS) {
        let _ = writeln!(applis, "{pct:5.1} %  {nom}");
    }
    let applis =
        if applis.is_empty() { "  (rien de notable)".to_owned() } else { echappe(applis.trim_end()) };
    let bulle = format!("<b>Processeur : {usage} %</b>\n<tt>{applis}</tt>");
    sortie(&format!("{ICONE_CPU}  {usage}%"), &bulle, "");
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
    // Totaux à chaque appel ; détail par application toutes les 15 s (il change lentement)
    let applis = detail_garde("panneaux-ram", || tableau(ram_par_appli(), total / 1024));

    let (mut vu, mut vt, mut vram) = (0, 0, String::new());
    if let Some(carte) = carte_gpu() {
        vu = lire_nombre(carte.join("mem_info_vram_used")).unwrap_or(0);
        vt = lire_nombre(carte.join("mem_info_vram_total")).unwrap_or(0);
        vram = detail_garde("panneaux-vram", || tableau(vram_par_appli(&carte), vt / 1024));
    }
    if vram.is_empty() {
        vram.push_str("  (aucune application)");
    }
    let bulle = format!(
        "<b>Mémoire : {} Go / {} Go</b>\n<tt>{applis}</tt>\n\n<b>Mémoire vidéo : {} Go / {} Go</b>\n<tt>{vram}</tt>",
        go(utilise),
        go(total),
        go(vu),
        go(vt)
    );
    sortie(&format!("{ICONE_RAM}  {pct}%"), &bulle, "");
}

/// Texte d'une valeur mesurée, ou "?" si elle manque.
fn ou_inconnu(valeur: Option<impl std::fmt::Display>) -> String {
    valeur.map_or_else(|| "?".to_owned(), |v| v.to_string())
}

/// Ventilateurs de la carte graphique : vitesse, et part de leur puissance maximale.
fn ventilateurs(hwmon: &Path) -> Option<String> {
    let tours = lire_nombre(hwmon.join("fan1_input"))?;
    Some(match lire_nombre(hwmon.join("pwm1")) {
        Some(pwm) => format!("{tours} tr/min ({} %)", pwm * 100 / 255),
        None => format!("{tours} tr/min"),
    })
}

fn capteur_gpu() {
    let Some(carte) = carte_gpu() else {
        sortie("", "", "");
        return;
    };
    let usage = lire_nombre(carte.join("gpu_busy_percent")).unwrap_or(0);
    let vu = lire_nombre(carte.join("mem_info_vram_used")).unwrap_or(0);
    let vt = lire_nombre(carte.join("mem_info_vram_total")).unwrap_or(0);
    let hwmon = premier_hwmon(&carte);
    let watts = |fichier: &str| hwmon.as_ref().and_then(|h| lire_nombre(h.join(fichier))).map(|p| p / 1_000_000);
    // Consommation, et la limite fixée (réglage "puissanceCarteGraphique" de games_drivers.nix)
    let puissance = match (watts("power1_average").or_else(|| watts("power1_input")), watts("power1_cap")) {
        (Some(p), Some(limite)) => format!("{p} W / {limite} W"),
        (p, _) => format!("{} W", ou_inconnu(p)),
    };
    let ventilation = ou_inconnu(hwmon.as_deref().and_then(ventilateurs));
    let frequence = ou_inconnu(
        lire(carte.join("pp_dpm_sclk"))
            .and_then(|t| t.lines().find(|l| l.contains('*'))?.split_whitespace().nth(1).map(str::to_owned)),
    );
    let bulle = format!(
        "<b>Carte graphique : {usage} %</b>\n<tt>Mémoire vidéo  {} Go / {} Go\nConsommation   {puissance}\nVentilateurs   {ventilation}\nFréquence      {frequence}</tt>",
        go(vu),
        go(vt)
    );
    sortie(&format!("{ICONE_GPU}  {usage}%"), &bulle, "");
}

/// Couleur selon la température.
const fn niveau(valeur: i64) -> &'static str {
    match valeur {
        v if v >= 90 => "critique",
        v if v >= 80 => "chaud",
        v if v >= 65 => "tiede",
        _ => "froid",
    }
}

/// Températures d'un capteur par étiquette ("edge", "junction", "mem"...), en °C.
fn temperatures(hwmon: &Path) -> HashMap<String, i64> {
    fs::read_dir(hwmon)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entree| {
            let nom = entree.file_name().into_string().ok()?;
            let numero = nom.strip_prefix("temp")?.strip_suffix("_label")?;
            let valeur = lire_nombre(hwmon.join(format!("temp{numero}_input")))?;
            Some((lire(entree.path())?, i64::try_from(valeur / 1000).ok()?))
        })
        .collect()
}

/// La carte graphique approche de sa coupure d'urgence (115 °C au point le plus chaud) :
/// notification, au plus une toutes les 2 minutes. Seuil : réglage "alerteChaleur".
fn alerter_chaleur(point: i64) {
    let Some(seuil) = THEME.alerte_chaleur else { return };
    let temoin = dossier_session().join("panneaux-alerte-chaleur");
    if point < seuil || age(&temoin).is_some_and(|age| age < Duration::from_secs(120)) {
        return;
    }
    let _ = fs::write(&temoin, "");
    let texte = format!(
        "Point le plus chaud : {point} °C (arrêt d'urgence à 115 °C). Baisse les réglages du jeu, \
         ou laisse-la refroidir."
    );
    lancer(&["notify-send", "-u", "critical", "-a", "temperature", "Carte graphique très chaude", &texte]);
}

fn capteur_temp() {
    // Une seule température dans la barre : celle de la carte graphique (couleur selon la
    // chaleur, rouge si le point le plus chaud atteint le seuil d'alerte). Survol : le détail
    // de la carte graphique, ses ventilateurs, et le processeur.
    let hwmon = carte_gpu().and_then(|c| premier_hwmon(&c));
    let temperatures = hwmon.as_deref().map(temperatures).unwrap_or_default();
    let (bord, point, mem) =
        (temperatures.get("edge").copied(), temperatures.get("junction").copied(), temperatures.get("mem").copied());
    if let Some(point) = point {
        alerter_chaleur(point);
    }
    let cpu = capteur_par_nom("k10temp")
        .and_then(|h| lire_nombre(h.join("temp1_input")))
        .and_then(|t| i64::try_from(t / 1000).ok());
    let bulle = format!(
        "<b>Carte graphique</b>\n<tt>Température           {} °C\nPoint le plus chaud   {} °C\nMémoire vidéo         {} °C\nVentilateurs          {}</tt>\n\n<b>Processeur</b>\n<tt>Température           {} °C</tt>",
        ou_inconnu(bord),
        ou_inconnu(point),
        ou_inconnu(mem),
        ou_inconnu(hwmon.as_deref().and_then(ventilateurs)),
        ou_inconnu(cpu)
    );
    let alerte = matches!((point, THEME.alerte_chaleur), (Some(p), Some(seuil)) if p >= seuil);
    let classe = if alerte { "critique" } else { niveau(bord.unwrap_or(0)) };
    sortie(&format!("{ICONE_TEMP}  {}°C", ou_inconnu(bord)), &bulle, classe);
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
    println!("{}", json!({ "text": icone, "tooltip": infobulle, "class": classes }));
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
    if drapeau_veille().exists() {
        texte.push_str(ICONE_CAFE);
        bulle.push_str("Veille automatique de l'ordinateur désactivée");
    }
    if let Some(prevu) = arret_prevu() {
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
    let fenetres = fenetres_reduites();
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
    if drapeau_veille().exists()
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
    let ecran = hyprland("monitors")
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
    // La suite s'affiche : c'est le programme des panneaux (avec GTK) qui prend le relais
    let mut suite = programme_panneaux();
    if ecran_entier {
        suite.args(["apercu", &fichier]);
    } else {
        suite.args(["selection", &fichier, &ecran]);
    }
    let _ = suite.exec();
}

/// Lanceur d'applications (Rofi). Relancer la commande le referme ; un clic n'importe où
/// ailleurs aussi, grâce à l'"attrape-clic" posé sous lui (attrape.rs).
fn lanceur() {
    if executer(&["pgrep", "-x", "rofi"]).0 {
        lancer(&["pkill", "-x", "rofi"]);
        return;
    }
    let attrape = programme_panneaux().arg("attrape").spawn().ok();
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
    fn noms_des_commandes() {
        let nom = |c: &str| nom_de_commande(c).unwrap_or_default();
        assert_eq!(nom("/nix/store/x-firefox/lib/firefox/firefox\0-contentproc\0"), "firefox");
        // titre réécrit, avec des espaces et des "/" dans les arguments
        assert_eq!(nom("/nix/store/x/libexec/electron/electron --type=renderer --user-data-dir=/home/a/.config/equibop-ptb/sessionData --x=/a/b"), "equibop-ptb");
        assert_eq!(nom("/nix/store/x/electron\0--flag\0/nix/store/y/opt/Equibop/resources/app.asar\0"), "equibop");
        assert_eq!(nom("/nix/store/x/bin/python3.13\0/nix/store/y/bin/.opensnitch-ui-wrapped\0"), "opensnitch-ui");
        assert_eq!(nom("python3\0-m\0http.server\0"), "http.server");
        assert_eq!(nom("/run/current-system/sw/bin/bash\0-c\0source x\0"), "bash");
        assert_eq!(nom_de_commande(""), None);
        assert_eq!(nom_de_commande("/proc/self/exe\0--type=utility\0"), None); // nom du noyau à la place
    }

    #[test]
    fn lecteur_petits_et_grands_fichiers() {
        let dossier = std::env::temp_dir();
        let (petit, grand) = (dossier.join("lecteur-petit"), dossier.join("lecteur-grand"));
        fs::write(&petit, "1 2 3\n").unwrap();
        fs::write(&grand, "abcdefghij".repeat(4000)).unwrap(); // 40 000 octets : plus que le tampon
        let mut lecteur = Lecteur::new();
        assert_eq!(lecteur.texte(&petit), Some("1 2 3\n"));
        assert_eq!(lecteur.texte(&grand).map(str::len), Some(40_000));
        assert_eq!(lecteur.texte(&petit), Some("1 2 3\n")); // tampon réutilisé (et agrandi)
        assert_eq!(lecteur.octets("/n/existe/pas"), None);
        assert!(lecteur.texte("/proc/self/stat").is_some_and(|s| s.contains(')')));
        let _ = (fs::remove_file(petit), fs::remove_file(grand));
    }

    #[test]
    fn mesure_gardee_puis_relue() {
        let mesure = Mesure { total: 123_456, inactif: 100_000, par_pid: HashMap::from([(1, 50), (4242, 7)]) };
        assert_eq!(Mesure::lire(&mesure.ecrire()), Some(mesure));
        assert_eq!(Mesure::lire(""), None);
        assert_eq!(Mesure::lire("abc"), None);
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
