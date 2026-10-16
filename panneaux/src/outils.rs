//! Briques d'affichage partagées par tous les panneaux (étiquettes, boutons, icônes, images).
//! Les outils sans affichage (lancer des programmes, interroger Hyprland...) sont dans
//! systeme.rs, repris ici tels quels.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, gdk_pixbuf, gio, glib, pango};

pub use crate::systeme::*;

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
// Travail en arrière-plan
// -----------------------------------------------------------------------------
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
    let image = gtk::Image::from_gicon(&icone_de(nom)?);
    image.set_pixel_size(taille);
    Some(image)
}

thread_local! {
    /// Icônes déjà cherchées (nom -> icône) : chaque application n'est cherchée qu'une fois,
    /// même avec plusieurs fenêtres, ou une grande et une petite image.
    static ICONES: RefCell<HashMap<String, Option<gio::Icon>>> = RefCell::new(HashMap::new());
}

fn icone_de(nom: &str) -> Option<gio::Icon> {
    if nom.is_empty() {
        return None;
    }
    if let Some(connue) = ICONES.with_borrow(|icones| icones.get(nom).cloned()) {
        return connue;
    }
    let trouvee = chercher_icone(nom);
    ICONES.with_borrow_mut(|icones| icones.insert(nom.to_owned(), trouvee.clone()));
    trouvee
}

/// Le fichier .desktop de l'application (par son nom exact, puis en minuscules, puis la
/// première application installée dont le nom ressemble), sinon l'icône du thème de ce nom.
fn chercher_icone(nom: &str) -> Option<gio::Icon> {
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
    icones.into_iter().find(|icone| match icone.downcast_ref::<gio::FileIcon>() {
        Some(fichier) => fichier.file().path().is_some_and(|p| p.exists()),
        None => theme.has_gicon(icone),
    })
}

// -----------------------------------------------------------------------------
// Cartes de fenêtres (Alt+Tab, partage d'écran)
// -----------------------------------------------------------------------------
/// Une carte : un cadre pour la miniature (avec l'icône de l'application en attendant),
/// puis la petite icône et le titre. Renvoie la carte et le cadre de sa miniature.
pub fn carte_fenetre(texte: &str, classe: &str, taille: (i32, i32), taille_icone: i32) -> (gtk::Box, gtk::CenterBox) {
    let zone = boite(true, 8);
    marges(&zone, 10);
    zone.add_css_class("carte");
    let cadre = gtk::CenterBox::new();
    cadre.set_size_request(taille.0, taille.1);
    cadre.add_css_class("miniature");
    match icone_appli(classe, taille_icone) {
        Some(image) => cadre.set_center_widget(Some(&image)),
        None => cadre.set_center_widget(Some(&etiquette_centree(icone::FENETRE, &["grosse-icone"]))),
    }
    zone.append(&cadre);
    let titre = boite(false, 6);
    if let Some(petite) = icone_appli(classe, 18) {
        titre.append(&petite);
    }
    let e = etiquette(texte, &[]);
    couper(&e, 26);
    e.set_hexpand(true);
    titre.append(&e);
    zone.append(&titre);
    (zone, cadre)
}

/// Capture un écran ou une fenêtre (cible : "-o ÉCRAN" ou "-T FENÊTRE") sans figer
/// l'affichage, puis pose la miniature dans `cadre` si `encore()` dit, à ce moment-là, que le
/// panneau est toujours affiché. L'image passe par la mémoire vive et n'y reste pas.
pub fn poser_miniature(
    cadre: &gtk::CenterBox,
    cible: &[&str],
    taille: (i32, i32),
    encore: impl Fn() -> bool + 'static,
) {
    let nom = cible.join("").replace(['/', ' '], "_");
    let chemin = dossier_session().join(format!("miniature-{nom}-{}.jpg", std::process::id()));
    let (c, cible) = (chemin.clone(), cible.iter().map(|m| (*m).to_owned()).collect::<Vec<_>>());
    let cadre = cadre.clone();
    en_fond(
        move || miniature_grim(&cible.iter().map(String::as_str).collect::<Vec<_>>(), &c.to_string_lossy()),
        move |reussi| {
            if reussi
                && encore()
                && let Some((image, _, _)) = image_ajustee(&chemin, taille.0, taille.1, true)
            {
                cadre.set_center_widget(Some(&image));
            }
            let _ = std::fs::remove_file(&chemin);
        },
    );
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
