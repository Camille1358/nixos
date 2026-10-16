//! Outils sans affichage, communs aux deux programmes : "panneaux" (les panneaux, avec GTK)
//! et "panneaux-barre" (les modules de la barre, sans GTK : il démarre en quelques
//! millisecondes). Lancer des programmes (avec le mode essai), interroger Hyprland, dossiers.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::sync::mpsc;
use std::time::Duration;

use chrono::{Local, NaiveDateTime, TimeZone};
use serde_json::Value;

// -----------------------------------------------------------------------------
// Dossiers
// -----------------------------------------------------------------------------
/// Dossier des fichiers temporaires de la session (en mémoire vive).
pub fn dossier_session() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
}

/// Dossier où les programmes gardent leur état (~/.local/state).
pub fn dossier_etat() -> PathBuf {
    match std::env::var_os("XDG_STATE_HOME") {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"),
    }
}

// -----------------------------------------------------------------------------
// Mode essai (lancer avec PANNEAUX_ESSAI=1) : les commandes qui changent quelque chose
// (éteindre, verrouiller, couper le réseau, connecter un appareil...) sont seulement
// affichées, jamais exécutées. Les commandes qui ne font que lire restent permises.
// -----------------------------------------------------------------------------
pub static ESSAI: LazyLock<bool> =
    LazyLock::new(|| std::env::var_os("PANNEAUX_ESSAI").is_some_and(|v| !v.is_empty()));

const COMMANDES_SENSIBLES: [&str; 3] = ["systemctl", "systemd-run", "hyprlock"];
/// Pour ces outils, seuls ces mots-là (dans la commande) changent quelque chose :
const VERBES_SENSIBLES: [(&str, &[&str]); 5] = [
    ("hyprctl", &["dispatch", "eval"]),
    ("nmcli", &["on", "off", "up", "down", "connect", "disconnect", "delete"]),
    ("rfkill", &["block", "unblock"]),
    ("bluetoothctl", &["pair", "trust", "connect", "disconnect", "power", "remove"]),
    ("makoctl", &["-t", "-a", "-r", "dismiss"]),
];

/// En mode essai, affiche une commande sensible au lieu de l'exécuter.
fn retenue(commande: &[&str]) -> bool {
    if !*ESSAI || commande.is_empty() {
        return false;
    }
    let sensible = COMMANDES_SENSIBLES.contains(&commande[0])
        || VERBES_SENSIBLES.iter().any(|(outil, verbes)| {
            *outil == commande[0] && commande[1..].iter().any(|mot| verbes.contains(mot))
        });
    if sensible {
        eprintln!("[essai] non exécuté : {}", commande.join(" "));
    }
    sensible
}

// -----------------------------------------------------------------------------
// Lancer des programmes
// -----------------------------------------------------------------------------
/// Lance un programme sans attendre sa fin, détaché du panneau.
pub fn lancer(commande: &[&str]) {
    if commande.is_empty() || retenue(commande) {
        return;
    }
    let enfant = Command::new(commande[0])
        .args(&commande[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0) // détaché : il survit à la fermeture du panneau
        .spawn();
    // Programme introuvable : on ne fait rien plutôt que de planter le panneau.
    // Sinon, un fil attend sa fin pour qu'il ne reste pas en "zombie".
    if let Ok(mut enfant) = enfant {
        std::thread::spawn(move || enfant.wait());
    }
}

/// Lance un programme et attend sa fin (au plus 5 secondes).
/// Renvoie (réussi, texte affiché).
pub fn executer(commande: &[&str]) -> (bool, String) {
    executer_delai(commande, 5)
}

/// Comme executer, avec un délai maximal choisi (en secondes).
///
/// Les outils répondent en anglais (et non dans la langue du système) : leurs réponses
/// ("enabled", "blocked"...) peuvent ainsi être lues de façon sûre.
pub fn executer_delai(commande: &[&str], delai: u64) -> (bool, String) {
    if commande.is_empty() {
        return (false, String::new());
    }
    if retenue(commande) {
        return (true, String::new());
    }
    let Ok(mut enfant) = Command::new(commande[0])
        .args(&commande[1..])
        .env("LC_ALL", "C.UTF-8")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return (false, String::new());
    };
    // La sortie est lue à part : un programme bavard ne bloque jamais en attendant
    // qu'on le lise. La lecture finit quand le programme se termine.
    let mut sortie = enfant.stdout.take().expect("sortie demandée ci-dessus");
    let (envoi, reception) = mpsc::channel();
    std::thread::spawn(move || {
        let mut texte = Vec::new();
        let _ = sortie.read_to_end(&mut texte);
        let _ = envoi.send(texte);
    });
    match reception.recv_timeout(Duration::from_secs(delai)) {
        Ok(texte) => {
            let reussi = enfant.wait().is_ok_and(|statut| statut.success());
            (reussi, String::from_utf8_lossy(&texte).into_owned())
        }
        Err(_) => {
            // Trop long : on l'arrête
            let _ = enfant.kill();
            let _ = enfant.wait();
            (false, String::new())
        }
    }
}

/// Le programme "panneaux" (les panneaux, avec GTK), rangé à côté de celui-ci.
pub fn programme_panneaux() -> Command {
    let voisin = std::env::current_exe().ok().and_then(|moi| Some(moi.parent()?.join("panneaux")));
    Command::new(voisin.filter(|p| p.is_file()).unwrap_or_else(|| PathBuf::from("panneaux")))
}

/// Miniature d'un écran ou d'une fenêtre (cible : "-o ÉCRAN" ou "-T FENÊTRE") en JPEG réduit.
/// Certaines fenêtres (Steam, jeux XWayland en plein écran) ne livrent jamais d'image : grim
/// attendrait alors sans fin. "timeout -s KILL" l'arrête au bout de 2 s, même si le panneau
/// qui l'a lancé est déjà fermé (sinon ces captures restaient bloquées et s'accumulaient).
pub fn miniature_grim(cible: &[&str], destination: &str) -> bool {
    let mut commande = vec!["timeout", "-s", "KILL", "2", "grim"];
    commande.extend_from_slice(cible);
    commande.extend(["-s", "0.3", "-t", "jpeg", "-q", "80", destination]);
    executer_delai(&commande, 3).0 && Path::new(destination).exists()
}

pub fn notifier(titre: &str, texte: &str, urgent: bool) {
    if urgent {
        lancer(&["notify-send", "-u", "critical", titre, texte]);
    } else {
        lancer(&["notify-send", titre, texte]);
    }
}

/// Demande à la barre (Waybar) de mettre à jour un module (8 état, 9 réduites,
/// 10 notifications).
pub fn rafraichir_barre(signal: u8) {
    lancer(&["pkill", &format!("-RTMIN+{signal}"), "waybar"]);
}

/// Chemin complet d'un programme d'après le PATH (comme la commande "which").
pub fn chercher_programme(nom: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dossier| dossier.join(nom))
        .find(|chemin| chemin.is_file())
}

/// Déplace un fichier, même vers un autre disque.
pub fn deplacer(source: &Path, destination: &Path) -> std::io::Result<()> {
    if std::fs::rename(source, destination).is_ok() {
        return Ok(());
    }
    std::fs::copy(source, destination)?;
    std::fs::remove_file(source)
}

// -----------------------------------------------------------------------------
// Hyprland
// -----------------------------------------------------------------------------
/// Interroge Hyprland ("clients", "monitors", "cursorpos"...) ; renvoie la réponse JSON
/// décodée (Null en cas d'échec). Par sa prise de communication, comme hyprctl, mais sans
/// lancer de programme : bien plus rapide (la barre et le défilement l'appellent souvent).
pub fn hyprland(question: &str) -> Value {
    let Some(signature) = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") else {
        return Value::Null;
    };
    let chemin = dossier_session().join("hypr").join(signature).join(".socket.sock");
    let Ok(mut prise) = UnixStream::connect(chemin) else { return Value::Null };
    let _ = prise.set_read_timeout(Some(Duration::from_secs(2)));
    let mut reponse = Vec::new();
    if prise.write_all(format!("j/{question}").as_bytes()).is_err() || prise.read_to_end(&mut reponse).is_err()
    {
        return Value::Null;
    }
    serde_json::from_slice(&reponse).unwrap_or(Value::Null)
}

const ESPACE_REDUITES: &str = "special:reduites";

/// Fenêtres réduites (bouton "réduire" des fenêtres, ou Super+N) : leurs descriptions Hyprland.
pub fn fenetres_reduites() -> Vec<Value> {
    match hyprland("clients") {
        Value::Array(fenetres) => fenetres
            .into_iter()
            .filter(|f| f["workspace"]["name"].as_str() == Some(ESPACE_REDUITES))
            .collect(),
        _ => Vec::new(),
    }
}

// -----------------------------------------------------------------------------
// Session
// -----------------------------------------------------------------------------
/// Si ce fichier existe, la veille automatique de l'ordinateur est désactivée
/// (même convention que le script "veille-auto" de desktop-home.nix).
pub fn drapeau_veille() -> PathBuf {
    dossier_session().join("veille-auto-desactivee")
}

/// Moment de l'arrêt programmé, ou None s'il n'y en a pas. Tant qu'un arrêt est prévu, logind
/// le note dans un petit fichier : le lire est bien plus léger que d'interroger logind (la barre
/// le demande toutes les 30 s). S'il est illisible, on interroge logind.
pub fn arret_prevu() -> Option<NaiveDateTime> {
    match std::fs::read_to_string("/run/systemd/shutdown/scheduled") {
        Ok(texte) => moment_de_l_arret(&texte),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None, // aucun arrêt prévu
        Err(_) => arret_prevu_selon_logind(),
    }
}

/// Le fichier de logind : "USEC=<moment de l'arrêt, en microsecondes depuis 1970>", "MODE=…"…
fn moment_de_l_arret(fichier: &str) -> Option<NaiveDateTime> {
    let microsecondes = fichier.lines().find_map(|l| l.strip_prefix("USEC="))?.trim().parse().ok()?;
    Some(Local.timestamp_micros(microsecondes).single()?.naive_local())
}

fn arret_prevu_selon_logind() -> Option<NaiveDateTime> {
    let (_, texte) = executer(&[
        "busctl",
        "get-property",
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
        "ScheduledShutdown",
    ]);
    let champs: Vec<&str> = texte.split_whitespace().collect(); // exemple : (st) "poweroff" 1791234567000000
    if champs.len() < 3 || champs[1] == "\"\"" {
        return None;
    }
    let microsecondes: i64 = champs[2].parse().ok()?;
    Some(Local.timestamp_micros(microsecondes).single()?.naive_local())
}

#[cfg(test)]
mod essais {
    use chrono::{Local, TimeZone};

    use super::moment_de_l_arret;

    #[test]
    fn arret_programme() {
        let attendu = Local.timestamp_micros(1_791_234_567_000_000).single().map(|d| d.naive_local());
        assert_eq!(moment_de_l_arret("USEC=1791234567000000\nWARN_WALL=1\nMODE=poweroff\nUID=1000\n"), attendu);
        assert_eq!(moment_de_l_arret("MODE=poweroff\n"), None);
        assert_eq!(moment_de_l_arret(""), None);
    }
}
