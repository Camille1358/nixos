//! Outils communs : lancer des programmes (avec le mode essai), et les briques
//! d'affichage partagées par tous les panneaux (étiquettes, boutons, icônes).

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::sync::mpsc;
use std::time::Duration;

use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, gdk_pixbuf, gio, glib, pango};
use serde_json::Value;

// -----------------------------------------------------------------------------
// Icônes de la police Nerd Font (liste : https://www.nerdfonts.com/cheat-sheet)
// -----------------------------------------------------------------------------
pub mod icone {
    pub const PRECEDENT: &str = "\u{f053}";
    pub const SUIVANT: &str = "\u{f054}";
    pub const ETEINDRE: &str = "\u{f011}";
    pub const REDEMARRER: &str = "\u{f021}";
    pub const VEILLE: &str = "\u{f186}";
    pub const SABLIER: &str = "\u{f253}";
    pub const ANNULER: &str = "\u{f00d}";
    pub const CAFE: &str = "\u{f0f4}";
    pub const LIT: &str = "\u{f236}";
    pub const CADENAS: &str = "\u{f023}";
    pub const SORTIR: &str = "\u{f08b}";
    pub const SON: &str = "\u{f028}";
    pub const SON_COUPE: &str = "\u{f026}";
    pub const MICRO: &str = "\u{f130}";
    pub const MICRO_COUPE: &str = "\u{f131}";
    pub const COCHE: &str = "\u{f00c}";
    pub const REGLAGES: &str = "\u{f1de}";
    pub const FENETRE: &str = "\u{f2d0}";
    pub const TOUT: &str = "\u{f2d2}";
    pub const COPIER: &str = "\u{f0c5}";
    pub const ENREGISTRER: &str = "\u{f0c7}";
    pub const DOSSIER: &str = "\u{f07c}";
    pub const WIFI: &str = "\u{f1eb}";
    pub const AVION: &str = "\u{f072}";
    pub const BLUETOOTH: &str = "\u{f293}";
    pub const ETHERNET: &str = "\u{f0200}";
    pub const RECHERCHE: &str = "\u{f002}";
    pub const CASQUE: &str = "\u{f025}";
    pub const CLAVIER: &str = "\u{f11c}";
    pub const SOURIS: &str = "\u{f245}";
    pub const TELEPHONE: &str = "\u{f10b}";
    pub const MANETTE: &str = "\u{f11b}";
    pub const CLOCHE: &str = "\u{f0f3}";
    pub const CLOCHE_BARREE: &str = "\u{f1f6}";
    pub const POUBELLE: &str = "\u{f1f8}";
    pub const TEXTE: &str = "\u{f031}";
}

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
        _ => glib::home_dir().join(".local/state"),
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

/// Exécute travail() sans figer l'affichage, puis puis(résultat) dans l'affichage.
/// Pour les actions lentes : connexion Wi-Fi, recherche Bluetooth, miniatures...
pub fn en_fond<T: Send + 'static>(
    travail: impl FnOnce() -> T + Send + 'static,
    puis: impl FnOnce(T) + 'static,
) {
    glib::spawn_future_local(async move {
        if let Ok(resultat) = gio::spawn_blocking(travail).await {
            puis(resultat);
        }
    });
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

/// Interroge Hyprland ; renvoie la réponse JSON décodée (Null en cas d'échec).
pub fn hyprland(question: &str) -> Value {
    serde_json::from_str(&executer(&["hyprctl", "-j", question]).1).unwrap_or(Value::Null)
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
// Briques d'affichage
// -----------------------------------------------------------------------------
pub fn vider(conteneur: &gtk::Box) {
    while let Some(enfant) = conteneur.first_child() {
        conteneur.remove(&enfant);
    }
}

pub fn boite(verticale: bool, espace: i32) -> gtk::Box {
    let sens = if verticale { gtk::Orientation::Vertical } else { gtk::Orientation::Horizontal };
    gtk::Box::new(sens, espace)
}

pub fn separateur() -> gtk::Separator {
    gtk::Separator::new(gtk::Orientation::Horizontal)
}

pub fn marges(widget: &impl IsA<gtk::Widget>, taille: i32) {
    widget.set_margin_top(taille);
    widget.set_margin_bottom(taille);
    widget.set_margin_start(taille);
    widget.set_margin_end(taille);
}

/// Texte aligné à gauche, avec ses classes de style.
pub fn etiquette(texte: &str, classes: &[&str]) -> gtk::Label {
    let e = gtk::Label::new(Some(texte));
    e.set_xalign(0.0);
    for classe in classes {
        e.add_css_class(classe);
    }
    e
}

/// Texte centré.
pub fn etiquette_centree(texte: &str, classes: &[&str]) -> gtk::Label {
    let e = etiquette(texte, classes);
    e.set_xalign(0.5);
    e
}

/// Texte trop long : coupé avec "…" au-delà de `largeur` caractères.
pub fn couper(e: &gtk::Label, largeur: i32) {
    e.set_ellipsize(pango::EllipsizeMode::End);
    e.set_max_width_chars(largeur);
}

/// Bouton plat, sans action (on la branche ensuite avec connect_clicked).
/// La sélection suit la souris : survoler un bouton lui donne le "curseur".
pub fn bouton_nu(classes: &[&str]) -> gtk::Button {
    let b = gtk::Button::new();
    b.set_has_frame(false);
    for classe in classes {
        b.add_css_class(classe);
    }
    let survol = gtk::EventControllerMotion::new();
    let faible = b.downgrade();
    survol.connect_enter(move |_, _, _| {
        if let Some(b) = faible.upgrade() {
            b.grab_focus();
        }
    });
    b.add_controller(survol);
    b
}

/// Bouton plat avec un texte. `action` est appelée au clic.
pub fn bouton(texte: &str, classes: &[&str], action: impl Fn() + 'static) -> gtk::Button {
    let b = bouton_nu(classes);
    b.set_label(texte);
    b.connect_clicked(move |_| action());
    b
}

/// Bouton plat : une icône, puis un texte (coupé au-delà de `largeur_max` caractères ; 0 = jamais).
pub fn bouton_icone(
    icone: &str,
    texte: &str,
    largeur_max: i32,
    classes: &[&str],
    action: impl Fn() + 'static,
) -> gtk::Button {
    let b = bouton_nu(classes);
    let rangee = boite(false, 10);
    rangee.append(&etiquette_centree(icone, &["icone"]));
    let texte = etiquette(texte, &[]);
    texte.set_hexpand(true);
    if largeur_max > 0 {
        couper(&texte, largeur_max);
    }
    rangee.append(&texte);
    b.set_child(Some(&rangee));
    b.connect_clicked(move |_| action());
    b
}

/// Image de l'application (d'après son nom ou sa classe de fenêtre), ou None.
pub fn icone_appli(nom: &str, taille: i32) -> Option<gtk::Image> {
    if nom.is_empty() {
        return None;
    }
    let affichage = gdk::Display::default()?;
    let theme = gtk::IconTheme::for_display(&affichage);
    let mut icones: Vec<gio::Icon> = Vec::new();
    let minuscule = nom.to_lowercase();
    let mut essais = vec![nom];
    if minuscule != nom {
        essais.push(&minuscule);
    }
    for essai in essais {
        if let Some(i) = gio_unix::DesktopAppInfo::new(&format!("{essai}.desktop")).and_then(|a| a.icon()) {
            icones.push(i);
        }
    }
    if icones.is_empty() {
        // Sinon : la première application installée dont le nom ressemble
        'recherche: for groupe in gio_unix::DesktopAppInfo::search(nom) {
            for ident in groupe {
                if let Some(i) = gio_unix::DesktopAppInfo::new(&ident).and_then(|a| a.icon()) {
                    icones.push(i);
                    break 'recherche;
                }
            }
        }
    }
    icones.push(gio::ThemedIcon::new(&minuscule).upcast());
    let icone = icones.into_iter().find(|icone| match icone.downcast_ref::<gio::FileIcon>() {
        Some(fichier) => fichier.file().path().is_some_and(|p| p.exists()),
        None => theme.has_gicon(icone),
    })?;
    let image = gtk::Image::from_gicon(&icone);
    image.set_pixel_size(taille);
    Some(image)
}

/// Pixels réels par point d'écran (1,5 sur un écran 4K à l'échelle 1,5) : la plus grande
/// échelle parmi les écrans branchés.
pub fn densite_ecran() -> f64 {
    let Some(affichage) = gdk::Display::default() else { return 1.0 };
    let moniteurs = affichage.monitors();
    (0..moniteurs.n_items())
        .filter_map(|i| moniteurs.item(i).and_downcast::<gdk::Monitor>())
        .map(|m| m.scale())
        .fold(1.0, f64::max)
}

/// Image d'un fichier, mise à l'échelle pour tenir dans largeur × hauteur points (agrandie
/// seulement si `agrandir`). Renvoie aussi la taille d'origine, en pixels.
///
/// Nette : l'image est préparée à la densité de l'écran (1,5 pixel par point à l'échelle 1,5)
/// puis affichée à sa taille en points, si bien qu'un pixel de l'image tombe sur un pixel de
/// l'écran. Une petite image s'affiche à sa taille réelle, sans être agrandie.
pub fn image_ajustee(
    chemin: &Path,
    largeur: i32,
    hauteur: i32,
    agrandir: bool,
) -> Option<(gtk::Widget, i32, i32)> {
    let (_, l, h) = gdk_pixbuf::Pixbuf::file_info(chemin)?;
    let densite = densite_ecran();
    let (l_points, h_points) = (l as f64 / densite, h as f64 / densite); // taille réelle, en points
    let echelle = (largeur as f64 / l_points).min(hauteur as f64 / h_points);
    let echelle = if agrandir { echelle } else { echelle.min(1.0) };
    // Taille affichée (points) et taille de l'image préparée (pixels de l'écran)
    let (la, ha) =
        (((l_points * echelle).round() as i32).max(1), ((h_points * echelle).round() as i32).max(1));
    let (lp, hp) =
        (((l as f64 * echelle).round() as i32).max(1), ((h as f64 * echelle).round() as i32).max(1));
    let image = if (lp, hp) == (l, h) {
        gdk_pixbuf::Pixbuf::from_file(chemin).ok()? // taille réelle : rien à recalculer
    } else {
        gdk_pixbuf::Pixbuf::from_file_at_scale(chemin, lp, hp, false).ok()?
    };
    let format = if image.has_alpha() { gdk::MemoryFormat::R8g8b8a8 } else { gdk::MemoryFormat::R8g8b8 };
    let texture = gdk::MemoryTexture::new(
        image.width(),
        image.height(),
        format,
        &image.read_pixel_bytes(),
        image.rowstride() as usize,
    );
    // Image "nette" : GTK la place à sa taille en points, et la dessine à partir des pixels
    // préparés ci-dessus (sinon il prendrait la taille en pixels pour une taille en points,
    // et l'image serait 1,5 fois trop grande)
    let photo = gtk::Picture::for_paintable(&ImageNette::new(texture.upcast(), la, ha));
    photo.set_can_shrink(false);
    photo.set_halign(gtk::Align::Center);
    photo.set_valign(gtk::Align::Center);
    Some((photo.upcast(), l, h))
}

/// Image dont la taille annoncée à GTK est en points, et le contenu en pixels réels.
mod nette {
    use std::cell::{Cell, RefCell};

    use gtk::prelude::*;
    use gtk::subclass::prelude::*;
    use gtk::{gdk, glib, graphene};

    #[derive(Default)]
    pub struct ImageNette {
        pub texture: RefCell<Option<gdk::Texture>>,
        pub taille: Cell<(i32, i32)>, // en points
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ImageNette {
        const NAME: &'static str = "PanneauxImageNette";
        type Type = super::ImageNette;
        type Interfaces = (gdk::Paintable,);
    }

    impl ObjectImpl for ImageNette {}

    impl PaintableImpl for ImageNette {
        fn intrinsic_width(&self) -> i32 {
            self.taille.get().0
        }

        fn intrinsic_height(&self) -> i32 {
            self.taille.get().1
        }

        fn snapshot(&self, snapshot: &gdk::Snapshot, largeur: f64, hauteur: f64) {
            if let (Some(texture), Some(snapshot)) =
                (self.texture.borrow().as_ref(), snapshot.downcast_ref::<gtk::Snapshot>())
            {
                snapshot
                    .append_texture(texture, &graphene::Rect::new(0.0, 0.0, largeur as f32, hauteur as f32));
            }
        }
    }
}

glib::wrapper! {
    pub struct ImageNette(ObjectSubclass<nette::ImageNette>) @implements gdk::Paintable;
}

impl ImageNette {
    fn new(texture: gdk::Texture, largeur: i32, hauteur: i32) -> Self {
        let image: Self = glib::Object::new();
        image.imp().texture.replace(Some(texture));
        image.imp().taille.set((largeur, hauteur));
        image
    }
}
