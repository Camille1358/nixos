//! Panneaux de la barre et du bureau :
//!
//!   panneaux calendrier | session | son | reduites | capture FICHIER   panneaux déroulants
//!   panneaux reseau          réseau et Bluetooth (comme KDE Plasma)
//!   panneaux notifications   historique des notifications, par application
//!   panneaux alttab          miniatures de l'Alt+Tab (la logique est dans Hyprland)
//!   panneaux attrape         "attrape-clic" posé sous le lanceur Rofi
//!
//! Relancer la même commande referme le panneau. Un clic n'importe où en dehors,
//! ou la touche Échap, le referme aussi.
//! Couleurs, police et réglages viennent de desktop-home.nix (voir style.rs).

mod alttab;
mod attrape;
mod barre;
mod calendrier;
mod capture;
mod notifications;
mod outils;
mod reduites;
mod reseau;
mod session;
mod son;
mod style;

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{gdk, gio, glib, graphene};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use outils::marges;
use style::THEME;

const MARGE: i32 = 12; // espace autour du panneau et à l'intérieur, en pixels

const PANNEAUX: [&str; 8] =
    ["calendrier", "session", "son", "reduites", "capture", "reseau", "notifications", "alttab"];

/// L'état commun : le panneau affiché (un seul à la fois).
pub struct Panneaux {
    pub app: gio::Application,
    fenetre: RefCell<Option<gtk::Window>>,
    /// Tant qu'un panneau est affiché, le programme ne se termine pas
    maintien: RefCell<Option<gio::ApplicationHoldGuard>>,
    mode: RefCell<Option<String>>,
    /// Numéro du panneau affiché : une action lente vérifie, quand elle se termine,
    /// que son panneau est toujours celui qui est affiché.
    numero: Cell<u64>,
    /// À faire à la fermeture (ex. effacer une capture ni copiée ni enregistrée)
    a_la_fermeture: RefCell<Option<Box<dyn FnOnce()>>>,
    /// 2e argument de la commande (ex. le fichier de la capture)
    pub parametre: RefCell<Option<String>>,
}

pub type App = Rc<Panneaux>;

impl Panneaux {
    pub fn numero(&self) -> u64 {
        self.numero.get()
    }

    /// Le panneau numéro `numero` est-il toujours affiché ?
    pub fn affiche(&self, numero: u64) -> bool {
        self.numero.get() == numero && self.fenetre.borrow().is_some()
    }

    pub fn quand_fermer(&self, action: impl FnOnce() + 'static) {
        self.a_la_fermeture.replace(Some(Box::new(action)));
    }

    pub fn fermer(&self) {
        let action = self.a_la_fermeture.borrow_mut().take();
        if let Some(action) = action {
            action();
        }
        self.mode.replace(None);
        self.numero.set(self.numero.get() + 1);
        let fenetre = self.fenetre.borrow_mut().take();
        if let Some(fenetre) = fenetre {
            fenetre.destroy();
        }
        self.maintien.take(); // plus aucun panneau : le programme se termine
    }

    fn nouvelle_fenetre(
        self: &Rc<Self>,
        espace_de_nom: &str,
        couche: Layer,
        clavier: KeyboardMode,
    ) -> gtk::Window {
        let fenetre = gtk::Window::new();
        self.maintien.replace(Some(self.app.hold()));
        fenetre.init_layer_shell();
        fenetre.set_namespace(Some(espace_de_nom));
        fenetre.set_layer(couche);
        fenetre.set_keyboard_mode(clavier);
        // Panneau retiré par le compositeur (ex. écran débranché) : on ferme proprement,
        // sinon le programme resterait en mémoire sans rien afficher.
        let app = Rc::clone(self);
        fenetre.connect_hide(move |fenetre| {
            if app.fenetre.borrow().as_ref() == Some(fenetre) {
                app.fermer();
            }
        });
        fenetre
    }

    fn ouvrir(self: &Rc<Self>, mode: &str) {
        self.numero.set(self.numero.get() + 1);
        if mode == "alttab" {
            self.ouvrir_alttab();
            return;
        }
        // Surface transparente qui couvre tout l'écran, au-dessus de tout : c'est elle
        // qui reçoit le clic "en dehors du panneau" et les touches du clavier.
        let fenetre = self.nouvelle_fenetre("panneau", Layer::Overlay, KeyboardMode::Exclusive);
        for bord in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
            fenetre.set_anchor(bord, true);
        }
        fenetre.set_exclusive_zone(-1); // recouvre aussi la barre
        self.fenetre.replace(Some(fenetre.clone()));
        self.mode.replace(Some(mode.to_owned()));

        let vue = match mode {
            "calendrier" => calendrier::creer(),
            "session" => session::creer(self),
            "son" => son::creer(self),
            "reduites" => reduites::creer(self),
            "capture" => capture::creer(self),
            "reseau" => reseau::creer(self),
            _ => notifications::creer(),
        };
        marges(&vue, MARGE);

        // Le cadre visible : en haut à droite sous la barre ; au centre pour une capture
        let cadre = outils::boite(true, 0);
        cadre.set_widget_name("panneau");
        cadre.append(&vue);
        if mode == "capture" {
            cadre.set_halign(gtk::Align::Center);
            cadre.set_valign(gtk::Align::Center);
        } else {
            cadre.set_halign(gtk::Align::End);
            cadre.set_valign(gtk::Align::Start);
            cadre.set_margin_top(THEME.hauteur_barre + 8);
            cadre.set_margin_end(MARGE);
        }
        let fond = outils::boite(true, 0);
        fond.append(&cadre);
        fenetre.set_child(Some(&fond));

        // Clic : en dehors du cadre, il referme le panneau
        let clic = gtk::GestureClick::new();
        clic.set_button(0); // tous les boutons de la souris
        let app = Rc::clone(self);
        let (fond_faible, cadre_faible) = (fond.downgrade(), cadre.downgrade());
        clic.connect_pressed(move |_, _, x, y| {
            let (Some(fond), Some(cadre)) = (fond_faible.upgrade(), cadre_faible.upgrade()) else {
                return;
            };
            let dedans = cadre
                .compute_bounds(&fond)
                .is_some_and(|zone| zone.contains_point(&graphene::Point::new(x as f32, y as f32)));
            if *outils::ESSAI {
                eprintln!(
                    "[essai] clic en {x:.0},{y:.0} : {}",
                    if dedans { "dans le panneau" } else { "en dehors" }
                );
            }
            if !dedans {
                app.fermer();
            }
        });
        fond.add_controller(clic);

        let touches = gtk::EventControllerKey::new();
        let app = Rc::clone(self);
        touches.connect_key_pressed(move |_, touche, _, _| {
            if touche == gdk::Key::Escape {
                app.fermer();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        fenetre.add_controller(touches);

        // Aucun bouton présélectionné à l'ouverture : sinon un appui sur Entrée ou Espace
        // juste après avoir ouvert le menu session éteindrait l'ordinateur.
        fenetre.connect_map(|fenetre| {
            GtkWindowExt::set_focus(fenetre, None::<&gtk::Widget>);
            let faible = fenetre.downgrade();
            glib::idle_add_local_once(move || {
                if let Some(fenetre) = faible.upgrade() {
                    GtkWindowExt::set_focus(&fenetre, None::<&gtk::Widget>);
                    if *outils::ESSAI {
                        eprintln!(
                            "[essai] bouton sélectionné à l'ouverture : {:?}",
                            GtkWindowExt::focus(&fenetre).map(|w| w.type_())
                        );
                    }
                }
            });
        });
        fenetre.present();
    }

    /// Miniatures de l'Alt+Tab : seulement un affichage, au centre de l'écran. Le clavier
    /// reste à Hyprland, qui gère Tab, les flèches, Échap et le relâchement d'Alt.
    fn ouvrir_alttab(self: &Rc<Self>) {
        let fenetre = self.nouvelle_fenetre("alttab", Layer::Overlay, KeyboardMode::None);
        self.fenetre.replace(Some(fenetre.clone()));
        self.mode.replace(Some("alttab".to_owned()));
        let vue = alttab::creer(self);
        if self.fenetre.borrow().is_none() {
            return; // choix déjà terminé dans Hyprland pendant la préparation
        }
        marges(&vue, 16);
        let cadre = outils::boite(true, 0);
        cadre.set_widget_name("panneau");
        cadre.append(&vue);
        fenetre.set_child(Some(&cadre));
        fenetre.present();
    }

    /// Appelé à chaque lancement de la commande, même si un panneau est déjà ouvert.
    fn commande(self: &Rc<Self>, arguments: &[String]) -> glib::ExitCode {
        let demande = arguments.get(1).map_or("", String::as_str);
        self.parametre.replace(arguments.get(2).cloned());
        if !PANNEAUX.contains(&demande) {
            eprintln!("usage : panneaux {} | attrape", PANNEAUX.join(" | "));
            return glib::ExitCode::FAILURE;
        }
        let deja_affiche = self.mode.borrow().clone();
        if demande == "alttab" {
            // Lancé une fois par Hyprland au premier Alt+Tab ; la suite (Tab, relâchement
            // d'Alt) est suivie par le panneau lui-même. Si le choix est déjà terminé
            // (Alt+Tab très rapide), rien à afficher.
            if deja_affiche.as_deref() != Some("alttab") && alttab::choix_en_cours().is_some() {
                self.fermer();
                self.ouvrir("alttab");
            }
            return glib::ExitCode::SUCCESS;
        }
        self.fermer();
        if demande == "reduites" && deja_affiche.as_deref() != Some(demande) {
            // Une seule fenêtre réduite : le clic sur l'icône la ramène directement,
            // sans passer par la liste (qui ne sert que s'il y en a plusieurs).
            let fenetres = reduites::fenetres_reduites();
            if let [seule] = fenetres.as_slice() {
                reduites::ramener(seule);
                outils::rafraichir_barre(9);
                return glib::ExitCode::SUCCESS;
            }
        }
        if deja_affiche.as_deref() != Some(demande) {
            // même panneau redemandé = on le referme seulement
            self.ouvrir(demande);
        }
        glib::ExitCode::SUCCESS
    }
}

/// Démarre GTK et charge la feuille de style. Renvoie false sans écran (affichage introuvable).
fn demarrer_gtk() -> bool {
    if let Err(erreur) = gtk::init() {
        eprintln!("panneaux : {erreur}");
        return false;
    }
    charger_style();
    true
}

fn charger_style() {
    let style = gtk::CssProvider::new();
    style.load_from_string(&style::feuille());
    if let Some(affichage) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&affichage, &style, gtk::STYLE_PROVIDER_PRIORITY_USER);
    }
}

fn main() -> glib::ExitCode {
    let arguments: Vec<String> = std::env::args().collect();
    // Modules de la barre et petites commandes : sans GTK, donc instantanés (barre.rs)
    if let Some(code) = barre::commande(&arguments) {
        return glib::ExitCode::from(code as u8);
    }
    if arguments.get(1).map(String::as_str) == Some("attrape") {
        return attrape::lancer(); // indépendant des panneaux : plusieurs peuvent coexister
    }

    // Une seule instance tourne à la fois : relancer la commande parle à celle-ci.
    // GApplication (et non GtkApplication) : GTK ne démarre que dans l'instance principale,
    // et ne charge pas tout le thème d'icônes au démarrage pour chercher une icône de fenêtre
    // (plusieurs milliers de fichiers lus : 3 à 4 fois plus lent). Les icônes sont chargées
    // seulement par les panneaux qui en affichent (notifications, Alt+Tab).
    let app = gio::Application::new(Some("fr.local.panneaux"), gio::ApplicationFlags::HANDLES_COMMAND_LINE);
    let gtk_pret = Rc::new(Cell::new(false));
    let pret = Rc::clone(&gtk_pret);
    app.connect_startup(move |_| pret.set(demarrer_gtk()));
    let etat: App = Rc::new(Panneaux {
        app: app.clone(),
        fenetre: RefCell::new(None),
        maintien: RefCell::new(None),
        mode: RefCell::new(None),
        numero: Cell::new(0),
        a_la_fermeture: RefCell::new(None),
        parametre: RefCell::new(None),
    });
    app.connect_command_line(move |_, ligne| {
        if !gtk_pret.get() {
            return glib::ExitCode::FAILURE;
        }
        let arguments: Vec<String> =
            ligne.arguments().iter().map(|a| a.to_string_lossy().into_owned()).collect();
        etat.commande(&arguments)
    });
    app.run_with_args(&arguments)
}
