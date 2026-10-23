//! Modules de la barre du haut (Waybar) et petites commandes du bureau, dans "panneaux-barre"
//! (barre_seule.rs) : un programme sans GTK, qui démarre en une milliseconde.
//!
//!   panneaux-barre capteurs cpu|gpu|ram|temp   mesures : une ligne JSON toutes les 3 s
//!   panneaux-barre notifs                      cloche des notifications
//!   panneaux-barre etat                        témoin "veille auto désactivée" / "arrêt programmé"
//!   panneaux-barre reduites-barre              témoin des fenêtres réduites
//!   panneaux-barre volume up|down|mute         touches multimédia + petite notification
//!   panneaux-barre veille-auto                 appelé par hypridle : met l'ordinateur en veille
//!   panneaux-barre capture-ecran [ecran]       capture d'écran (zone, ou écran entier), puis l'aperçu
//!   panneaux-barre lanceur                     lanceur d'applications (Rofi) + attrape-clic
//!   panneaux-barre rafraichir 8|9|10           mettre à jour un module de la barre

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::FileExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

use chrono::{Datelike, Local, TimeZone};
use serde_json::{Value, json};

use crate::style::THEME;
use crate::systeme::{
    arret_prevu, dossier_etat, dossier_session, drapeau_veille, executer, fenetres_reduites, hyprland, lancer,
    rafraichir_barre,
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
        // mettre à jour un module de la barre (8 état, 9 réduites, 10 notifications)
        "rafraichir" => {
            if let Ok(signal @ 1..=30) = argument(2).parse::<u8>() {
                rafraichir_barre(signal);
            }
        }
        _ => return None,
    }
    Some(0)
}

fn sortie(texte: &str, infobulle: &str, classe: &str) -> String {
    json!({ "text": texte, "tooltip": infobulle, "class": classe }).to_string()
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
        self.relire(&fs::File::open(chemin).ok()?)
    }

    /// Contenu d'un fichier déjà ouvert, relu depuis le début : le noyau le refait à jour.
    fn relire(&mut self, fichier: &fs::File) -> Option<&[u8]> {
        let mut longueur = 0;
        loop {
            let lus = fichier.read_at(&mut self.tampon[longueur..], longueur as u64).ok()?;
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

/// Temps total et temps inactif du processeur depuis le démarrage (tous cœurs confondus), en
/// battements du noyau.
fn temps_processeur(lecteur: &mut Lecteur) -> (u64, u64) {
    let champs: Vec<u64> = lecteur
        .texte("/proc/stat")
        .and_then(|t| t.lines().next())
        .unwrap_or("")
        .split_ascii_whitespace()
        .skip(1)
        .filter_map(|c| c.parse().ok())
        .collect();
    (champs.iter().take(8).sum(), champs.get(3).copied().unwrap_or(0))
}

/// Un processus suivi par le capteur du processeur. Son fichier "stat" reste ouvert : le relire
/// coûte deux fois moins que le rouvrir, pour les ~600 processus, toutes les 3 s.
struct Suivi {
    stat: fs::File,
    temps: Option<u64>,  // temps de calcul depuis son lancement, à la mesure précédente
    comm: Vec<u8>,       // nom court pour le noyau : s'il change, le processus a lancé un autre programme
    nom: Option<String>, // nom lisible, cherché une seule fois (vide : sans nom)
}

/// Le nom court (entre parenthèses) et le temps de calcul, d'après /proc/<pid>/stat.
fn analyser_stat(stat: &[u8]) -> Option<(&[u8], u64)> {
    // Le nom peut contenir des espaces, des ")" ou des octets qui ne sont pas du texte : les
    // nombres reprennent après la dernière ")"
    let debut = stat.iter().position(|&o| o == b'(')?;
    let fin = stat.iter().rposition(|&o| o == b')')?;
    let nombres = std::str::from_utf8(stat.get(fin + 1..)?).ok()?;
    let mut temps = nombres.split_ascii_whitespace().skip(11).map(str::parse::<u64>);
    Some((stat.get(debut + 1..fin)?, temps.next()?.ok()? + temps.next()?.ok()?))
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
fn ram_par_appli(lecteur: &mut Lecteur) -> HashMap<String, u64> {
    let mut par_nom: HashMap<String, u64> = HashMap::new();
    for pid in pids() {
        // statm : 2e champ = pages présentes en mémoire vive (4 Kio)
        let pages: u64 = lecteur
            .texte(format!("/proc/{pid}/statm"))
            .and_then(|s| s.split_ascii_whitespace().nth(1)?.parse().ok())
            .unwrap_or(0);
        if pages > 0
            && let Some(nom) = nom_du_processus(pid, lecteur)
        {
            *par_nom.entry(nom).or_default() += pages * 4;
        }
    }
    par_nom
}

/// Mémoire vidéo par application : chaque programme qui utilise la carte graphique décrit sa
/// consommation dans /proc/<numéro>/fdinfo (seulement lisible pour tes propres programmes).
/// `identifiant` : l'adresse de la carte ("0000:03:00.0").
fn vram_par_appli(identifiant: &str, lecteur: &mut Lecteur) -> HashMap<String, u64> {
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
            let (mut cette_carte, mut client, mut vram) = (false, None, 0);
            for ligne in texte.lines() {
                if let Some(v) = ligne.strip_prefix("drm-pdev:") {
                    cette_carte = v.trim() == identifiant;
                } else if let Some(v) = ligne.strip_prefix("drm-client-id:") {
                    client = Some(v.trim());
                } else if let Some(v) = ligne.strip_prefix("drm-memory-vram:") {
                    vram = v.trim().trim_end_matches("KiB").trim().parse().unwrap_or(0);
                }
            }
            if cette_carte
                && let Some(client) = client
                && vus.insert(client.to_owned())
            {
                total += vram;
            }
        }
        if total > 0
            && let Some(nom) = nom_du_processus(pid, lecteur)
        {
            *par_nom.entry(nom).or_default() += total;
        }
    }
    par_nom
}

// =============================================================================
// Capteurs
// =============================================================================
/// Les mesures de la barre. Chaque module reste ouvert et écrit une ligne toutes les 3 s, que
/// la barre affiche à son arrivée : rien n'est relancé (le lancement coûtait plus que la mesure),
/// et ce qui sert d'une mesure à l'autre (la mesure précédente du processeur, les chemins des
/// capteurs...) reste en mémoire.
fn capteurs(mode: &str) {
    let mut mesurer: Box<dyn FnMut() -> String> = match mode {
        "cpu" => Box::new(capteur_cpu()),
        "ram" => Box::new(capteur_ram()),
        "gpu" => Box::new(capteur_gpu()),
        "temp" => Box::new(capteur_temp()),
        _ => return eprintln!("usage : panneaux-barre capteurs cpu|gpu|ram|temp"),
    };
    let mut barre = std::io::stdout().lock();
    // La barre fermée (plus personne ne lit) : on s'arrête
    while writeln!(barre, "{}", mesurer()).is_ok() {
        sleep(Duration::from_secs(3));
    }
}

fn capteur_cpu() -> impl FnMut() -> String {
    // Un fichier ouvert par processus : la limite habituelle (1 024) n'y suffirait pas toujours.
    // SAFETY : lit puis relève la limite de fichiers ouverts de ce seul programme.
    unsafe {
        let mut limite = std::mem::zeroed::<libc::rlimit>();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limite) == 0 {
            limite.rlim_cur = limite.rlim_max;
            libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limite);
        }
    }
    let mut lecteur = Lecteur::new();
    let mut suivis: HashMap<u32, Suivi> = HashMap::new();
    let mut avant = (0, 0);
    // L'activité depuis la mesure précédente (la moyenne depuis le démarrage serait trompeuse)
    let mut mesurer = move || {
        let (total, inactif) = temps_processeur(&mut lecteur);
        let ecoule = total.saturating_sub(avant.0).max(1) as f64;
        let usage = (100.0 - inactif.saturating_sub(avant.1) as f64 * 100.0 / ecoule + 0.5).clamp(0.0, 100.0) as i64;
        avant = (total, inactif);

        // Part de chaque programme dans la puissance totale (tous cœurs confondus) ; un programme
        // apparu depuis la mesure précédente n'a pas encore de point de départ : il attend la suivante.
        let mut par_nom: HashMap<String, f64> = HashMap::new();
        let mut anciens = std::mem::take(&mut suivis);
        for pid in pids() {
            let Some(mut suivi) = anciens.remove(&pid).or_else(|| {
                let stat = fs::File::open(format!("/proc/{pid}/stat")).ok()?;
                Some(Suivi { stat, temps: None, comm: Vec::new(), nom: None })
            }) else {
                continue;
            };
            // Illisible : processus fini (son numéro sera repris plus tard par un autre)
            let Some((comm, temps)) = lecteur.relire(&suivi.stat).and_then(analyser_stat) else { continue };
            if comm != suivi.comm {
                suivi.comm = comm.to_vec();
                suivi.nom = None;
            }
            let battements = suivi.temps.replace(temps).map_or(0, |t| temps.saturating_sub(t));
            if battements > 0 {
                let nom = suivi.nom.get_or_insert_with(|| nom_du_processus(pid, &mut lecteur).unwrap_or_default());
                if !nom.is_empty() {
                    *par_nom.entry(nom.clone()).or_default() += battements as f64 * 100.0 / ecoule;
                }
            }
            suivis.insert(pid, suivi);
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
        sortie(&format!("{ICONE_CPU}  {usage}%"), &bulle, "")
    };
    mesurer(); // le point de départ ; le premier affichage porte sur 0,3 s
    sleep(Duration::from_millis(300));
    mesurer
}

fn capteur_ram() -> impl FnMut() -> String {
    // Mémoire vive, puis mémoire vidéo : total utilisé, et les applications les plus gourmandes
    // avec leur part du total (colonne %).
    let carte = carte_gpu();
    let identifiant = carte.as_ref().and_then(|c| Some(fs::canonicalize(c).ok()?.file_name()?.to_str()?.to_owned()));
    let mut lecteur = Lecteur::new();
    let (mut tour, mut applis, mut vram) = (0, String::new(), String::new());
    move || {
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
        let vram_de = |fichier: &str| carte.as_ref().and_then(|c| lire_nombre(c.join(fichier))).unwrap_or(0);
        let (vu, vt) = (vram_de("mem_info_vram_used"), vram_de("mem_info_vram_total"));
        // Totaux à chaque fois ; détail par application toutes les 15 s (il change lentement,
        // et coûte cher à mesurer)
        if tour % 5 == 0 {
            applis = tableau(ram_par_appli(&mut lecteur), total / 1024);
            vram = identifiant.as_deref().map(|id| tableau(vram_par_appli(id, &mut lecteur), vt / 1024)).unwrap_or_default();
            if vram.is_empty() {
                vram.push_str("  (aucune application)");
            }
        }
        tour += 1;
        let bulle = format!(
            "<b>Mémoire : {} Go / {} Go</b>\n<tt>{applis}</tt>\n\n<b>Mémoire vidéo : {} Go / {} Go</b>\n<tt>{vram}</tt>",
            go(utilise),
            go(total),
            go(vu),
            go(vt)
        );
        sortie(&format!("{ICONE_RAM}  {pct}%"), &bulle, "")
    }
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

fn capteur_gpu() -> impl FnMut() -> String {
    let carte = carte_gpu();
    let hwmon = carte.as_deref().and_then(premier_hwmon);
    move || {
        let Some(carte) = &carte else { return sortie("", "", "") };
        let usage = lire_nombre(carte.join("gpu_busy_percent")).unwrap_or(0);
        let vu = lire_nombre(carte.join("mem_info_vram_used")).unwrap_or(0);
        let vt = lire_nombre(carte.join("mem_info_vram_total")).unwrap_or(0);
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
        sortie(&format!("{ICONE_GPU}  {usage}%"), &bulle, "")
    }
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

/// Température d'une sonde, en °C.
fn celsius(sonde: &Path) -> Option<i64> {
    i64::try_from(lire_nombre(sonde)? / 1000).ok()
}

/// Sondes de température d'un capteur, par étiquette ("edge", "junction", "mem"...).
fn sondes(hwmon: &Path) -> HashMap<String, PathBuf> {
    fs::read_dir(hwmon)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entree| {
            let nom = entree.file_name().into_string().ok()?;
            let numero = nom.strip_prefix("temp")?.strip_suffix("_label")?;
            Some((lire(entree.path())?, hwmon.join(format!("temp{numero}_input"))))
        })
        .collect()
}

fn capteur_temp() -> impl FnMut() -> String {
    // Une seule température dans la barre : celle de la carte graphique (couleur selon la
    // chaleur, rouge si le point le plus chaud atteint le seuil d'alerte). Survol : le détail
    // de la carte graphique, ses ventilateurs, et le processeur.
    let hwmon = carte_gpu().and_then(|c| premier_hwmon(&c));
    let sondes = hwmon.as_deref().map(sondes).unwrap_or_default();
    let processeur = capteur_par_nom("k10temp").map(|h| h.join("temp1_input"));
    let mut derniere_alerte: Option<Instant> = None;
    move || {
        let sonde = |etiquette: &str| celsius(sondes.get(etiquette)?);
        let (bord, point, mem) = (sonde("edge"), sonde("junction"), sonde("mem"));
        // Le point le plus chaud approche de la coupure d'urgence (115 °C) : notification, au plus
        // une toutes les 2 minutes. Seuil : réglage "alerteChaleur".
        let alerte = matches!((point, THEME.alerte_chaleur), (Some(p), Some(seuil)) if p >= seuil);
        if let Some(point) = point.filter(|_| alerte)
            && derniere_alerte.is_none_or(|moment| moment.elapsed() > Duration::from_secs(120))
        {
            derniere_alerte = Some(Instant::now());
            let texte = format!(
                "Point le plus chaud : {point} °C (arrêt d'urgence à 115 °C). Baisse les réglages du \
                 jeu, ou laisse-la refroidir."
            );
            lancer(&["notify-send", "-u", "critical", "-a", "temperature", "Carte graphique très chaude", &texte]);
        }
        let bulle = format!(
            "<b>Carte graphique</b>\n<tt>Température           {} °C\nPoint le plus chaud   {} °C\nMémoire vidéo         {} °C\nVentilateurs          {}</tt>\n\n<b>Processeur</b>\n<tt>Température           {} °C</tt>",
            ou_inconnu(bord),
            ou_inconnu(point),
            ou_inconnu(mem),
            ou_inconnu(hwmon.as_deref().and_then(ventilateurs)),
            ou_inconnu(processeur.as_deref().and_then(celsius))
        );
        let classe = if alerte { "critique" } else { niveau(bord.unwrap_or(0)) };
        sortie(&format!("{ICONE_TEMP}  {}°C", ou_inconnu(bord)), &bulle, classe)
    }
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

/// Nom de l'écran actif (celui de la souris et de la fenêtre active), ou "" s'il est inconnu.
fn ecran_actif() -> String {
    let ecrans = hyprland("monitors");
    let actif = ecrans.as_array().and_then(|liste| liste.iter().find(|e| e["focused"] == true));
    actif.and_then(|e| e["name"].as_str()).unwrap_or_default().to_owned()
}

/// Le programme "panneaux" (les panneaux, avec GTK), rangé à côté de celui-ci.
fn programme_panneaux() -> Command {
    let voisin = std::env::current_exe().ok().and_then(|moi| Some(moi.parent()?.join("panneaux")));
    Command::new(voisin.filter(|p| p.is_file()).unwrap_or_else(|| PathBuf::from("panneaux")))
}

/// Capture d'écran façon ShareX. L'écran où se trouve la souris est photographié à l'instant
/// même (tout est figé, sans le curseur), puis :
///   - zone : on choisit la zone sur cette photo, avec une loupe au pixel près (selection.rs) ;
///   - écran entier : l'aperçu s'ouvre directement.
///
/// L'aperçu propose Copier, Enregistrer, Enregistrer sous…, Texte (OCR) ou Annuler.
/// L'image attend en mémoire vive : copiée ou annulée, elle ne laisse aucune trace.
fn capture(ecran_entier: bool) {
    let ecran = ecran_actif();
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
    fn tableau_formate() {
        let mut e = HashMap::new();
        e.insert("firefox".to_owned(), 2 * 1024 * 1024);
        e.insert("a<b".to_owned(), 512 * 1024);
        let t = tableau(e, 8 * 1024 * 1024);
        assert_eq!(t, "  2.0 Go  firefox           25.0 %\n  512 Mo  a&lt;b                6.2 %");
    }
}
