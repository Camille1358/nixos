//! Sélecteur de partage d'écran (Discord, Equibop, navigateurs...), dans le style des panneaux.
//!
//! Quand une application demande à partager l'écran, le portail de Hyprland
//! (xdg-desktop-portal-hyprland) lance ce sélecteur à la place du sien (fenêtre blanche) :
//! réglage "custom_picker_binary", voir desktop-home.nix. On choisit un écran, une fenêtre
//! ou une zone ; la réponse est écrite pour le portail, qui l'attend dans ce format :
//!   [SELECTION]r/screen:DP-1         ("r" : se souvenir du choix pour cette application)
//!   [SELECTION]/window:123456
//!   [SELECTION]/region:DP-1@x,y,l,h
//! Rien d'écrit (Échap, clic à côté, Annuler) = partage annulé.
//!
//!   panneaux partage [--allow-token]

use std::cell::Cell;
use std::path::Path;
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{gio, glib};
use serde_json::Value;

use crate::App;
use crate::outils::{
    boite, bouton, bouton_icone, couper, dossier_session, en_fond, etiquette, etiquette_centree,
    hyprland, icone, icone_appli, image_ajustee, marges, miniature_grim,
};

const LARGEUR: i32 = 240; // taille d'une miniature, en points
const HAUTEUR: i32 = 150;
const PAR_LIGNE: usize = 4;

pub fn principal(arguments: &[String]) -> glib::ExitCode {
    let souvenir = arguments.iter().any(|a| a == "--allow-token");
    let app = gio::Application::new(None::<&str>, gio::ApplicationFlags::NON_UNIQUE);
    app.connect_startup(|_| {
        crate::demarrer_gtk();
    });
    app.connect_activate(move |app| {
        let etat = crate::nouvel_etat(app);
        etat.parametre.replace(Some(if souvenir { "r" } else { "" }.to_owned()));
        etat.ouvrir("partage");
    });
    app.run_with_args(&[] as &[&str])
}

/// Une fenêtre de la liste du portail : son numéro pour le portail, sa classe, son titre et
/// son adresse dans Hyprland (pour la miniature).
struct Fenetre {
    numero: String,
    classe: String,
    titre: String,
    adresse: String,
}

/// Liste donnée par le portail : "numéro[HC>]classe[HT>]titre[HE>]adresse[HA>]" à la suite.
fn fenetres_du_portail(liste: &str) -> Vec<Fenetre> {
    liste
        .split("[HA>]")
        .filter_map(|entree| {
            let (numero, reste) = entree.split_once("[HC>]")?;
            let (classe, reste) = reste.split_once("[HT>]")?;
            let (titre, adresse) = reste.split_once("[HE>]")?;
            let adresse = adresse.trim().parse::<u64>().map(|a| format!("0x{a:x}")).unwrap_or_default();
            Some(Fenetre {
                numero: numero.trim().to_owned(),
                classe: classe.to_owned(),
                titre: titre.to_owned(),
                adresse,
            })
        })
        .collect()
}

struct Partage {
    app: App,
    souvenir: Cell<bool>,
}

impl Partage {
    /// Écrit le choix pour le portail, puis ferme.
    fn choisir(&self, choix: &str) {
        let drapeau = if self.souvenir.get() { "r" } else { "" };
        println!("[SELECTION]{drapeau}/{choix}");
        self.app.fermer();
    }
}

pub fn creer(app: &App) -> gtk::Box {
    let souvenir = app.parametre.borrow().as_deref() == Some("r");
    let p = Rc::new(Partage { app: Rc::clone(app), souvenir: Cell::new(souvenir) });
    let racine = boite(true, 10);
    racine.append(&etiquette("PARTAGER L'ÉCRAN", &["titre"]));

    // Écrans
    let ecrans: Vec<Value> = hyprland("monitors").as_array().cloned().unwrap_or_default();
    racine.append(&etiquette("Écrans", &["discret"]));
    let rangee = boite(false, 12);
    rangee.set_halign(gtk::Align::Center); // cartes à leur taille, pas étirées
    for e in &ecrans {
        let nom = e["name"].as_str().unwrap_or("?").to_owned();
        let texte = format!("{nom}  ·  {} × {}", e["width"], e["height"]);
        let (carte, cadre) = carte(&texte, None);
        miniature(&cadre, &["-o", &nom], &format!("ecran-{nom}"));
        let (p2, choix) = (Rc::clone(&p), format!("screen:{nom}"));
        cliquable(&carte, move || p2.choisir(&choix));
        rangee.append(&carte);
    }
    racine.append(&rangee);

    // Fenêtres
    let fenetres = fenetres_du_portail(&std::env::var("XDPH_WINDOW_SHARING_LIST").unwrap_or_default());
    if !fenetres.is_empty() {
        racine.append(&etiquette("Fenêtres", &["discret"]));
        let clients: Vec<Value> = hyprland("clients").as_array().cloned().unwrap_or_default();
        let grille = gtk::Grid::new();
        grille.set_column_spacing(12);
        grille.set_halign(gtk::Align::Center);
        grille.set_row_spacing(12);
        for (i, f) in fenetres.iter().enumerate() {
            let texte = if f.titre.is_empty() { f.classe.clone() } else { f.titre.clone() };
            let (carte, cadre) = carte(&texte, Some(&f.classe));
            // Miniature : la fenêtre de Hyprland qui correspond (même adresse)
            if let Some(stable) =
                clients.iter().find(|c| c["address"].as_str() == Some(f.adresse.as_str())).and_then(|c| {
                    c["stableId"].as_str().map(str::to_owned).or_else(|| Some(c["stableId"].to_string()))
                })
            {
                miniature(&cadre, &["-T", &stable], &format!("fenetre-{stable}"));
            }
            let (p2, choix) = (Rc::clone(&p), format!("window:{}", f.numero));
            cliquable(&carte, move || p2.choisir(&choix));
            grille.attach(&carte, (i % PAR_LIGNE) as i32, (i / PAR_LIGNE) as i32, 1, 1);
        }
        let defilement = gtk::ScrolledWindow::new();
        defilement.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
        defilement.set_propagate_natural_height(true);
        defilement.set_max_content_height(560);
        defilement.set_child(Some(&grille));
        racine.append(&defilement);
    }

    // Zone, souvenir, annuler
    let actions = boite(false, 6);
    actions.set_halign(gtk::Align::Center);
    let p2 = Rc::clone(&p);
    actions.append(&bouton_icone(icone::TOUT, "Zone de l'écran…", 0, &[], move || {
        choisir_zone(&p2, &ecrans)
    }));
    let souvenir_bouton = bouton(&texte_souvenir(souvenir), if souvenir { &["choisi"] } else { &[] }, || {});
    let p2 = Rc::clone(&p);
    souvenir_bouton.connect_clicked(move |b| {
        p2.souvenir.set(!p2.souvenir.get());
        b.set_label(&texte_souvenir(p2.souvenir.get()));
        if p2.souvenir.get() {
            b.add_css_class("choisi");
        } else {
            b.remove_css_class("choisi");
        }
    });
    souvenir_bouton.set_tooltip_text(Some("L'application pourra repartager la même chose sans redemander"));
    actions.append(&souvenir_bouton);
    let app2 = Rc::clone(app);
    actions.append(&bouton_icone(icone::ANNULER, "Annuler", 0, &["danger"], move || app2.fermer()));
    racine.append(&actions);
    racine
}

fn texte_souvenir(actif: bool) -> String {
    format!("{}  Se souvenir de ce choix", if actif { icone::COCHE } else { "  " })
}

/// Une carte : la miniature (l'icône de l'application en attendant), puis le texte.
fn carte(texte: &str, classe: Option<&str>) -> (gtk::Box, gtk::CenterBox) {
    let zone = boite(true, 8);
    marges(&zone, 10);
    let cadre = gtk::CenterBox::new();
    cadre.set_size_request(LARGEUR, HAUTEUR);
    cadre.add_css_class("miniature");
    match classe.and_then(|c| icone_appli(c, 56)) {
        Some(image) => cadre.set_center_widget(Some(&image)),
        None => cadre.set_center_widget(Some(&etiquette_centree(icone::FENETRE, &["grosse-icone"]))),
    }
    zone.append(&cadre);
    let titre = boite(false, 6);
    if let Some(petite) = classe.and_then(|c| icone_appli(c, 18)) {
        titre.append(&petite);
    }
    let e = etiquette(texte, &[]);
    couper(&e, 26);
    e.set_hexpand(true);
    titre.append(&e);
    zone.append(&titre);
    zone.add_css_class("carte");
    // Survol : la carte s'éclaire (comme la carte choisie de l'Alt+Tab)
    let survol = gtk::EventControllerMotion::new();
    let z = zone.downgrade();
    survol.connect_enter(move |_, _, _| {
        if let Some(z) = z.upgrade() {
            z.add_css_class("choisie");
        }
    });
    let z = zone.downgrade();
    survol.connect_leave(move |_| {
        if let Some(z) = z.upgrade() {
            z.remove_css_class("choisie");
        }
    });
    zone.add_controller(survol);
    (zone, cadre)
}

fn cliquable(carte: &gtk::Box, action: impl Fn() + 'static) {
    let clic = gtk::GestureClick::new();
    clic.set_button(1);
    clic.connect_released(move |_, _, _, _| action());
    carte.add_controller(clic);
}

/// Capture réduite (écran : -o NOM ; fenêtre : -T IDENTIFIANT), sans figer l'affichage.
fn miniature(cadre: &gtk::CenterBox, cible: &[&str], nom: &str) {
    let chemin = dossier_session().join(format!("partage-{nom}-{}.jpg", std::process::id()));
    let c = chemin.clone();
    let cible: Vec<String> = cible.iter().map(|s| (*s).to_owned()).collect();
    let cadre = cadre.clone();
    en_fond(
        move || {
            let cible: Vec<&str> = cible.iter().map(String::as_str).collect();
            miniature_grim(&cible, &c.to_string_lossy())
        },
        move |reussi| {
            if reussi && let Some((image, _, _)) = image_ajustee(&chemin, LARGEUR, HAUTEUR, true) {
                cadre.set_center_widget(Some(&image));
            }
            let _ = std::fs::remove_file(&chemin);
        },
    );
}

/// Zone de l'écran : le sélecteur disparaît, on trace la zone (slurp), puis la réponse est
/// donnée en coordonnées de l'écran concerné.
fn choisir_zone(p: &Rc<Partage>, ecrans: &[Value]) {
    let maintien = p.app.app.hold(); // le programme continue pendant la sélection
    let souvenir = p.souvenir.get();
    p.app.fermer();
    let ecrans: Vec<(String, i64, i64)> = ecrans
        .iter()
        .map(|e| {
            (
                e["name"].as_str().unwrap_or("").to_owned(),
                e["x"].as_i64().unwrap_or(0),
                e["y"].as_i64().unwrap_or(0),
            )
        })
        .collect();
    en_fond(
        || std::process::Command::new("slurp").args(["-f", "%o %x %y %w %h"]).output().ok(),
        move |sortie| {
            if let Some(sortie) = sortie.filter(|s| s.status.success()) {
                let texte = String::from_utf8_lossy(&sortie.stdout);
                let champs: Vec<&str> = texte.split_whitespace().collect();
                if let [nom, x, y, l, h] = champs[..]
                    && let (Ok(x), Ok(y)) = (x.parse::<i64>(), y.parse::<i64>())
                    && let Some((_, ex, ey)) = ecrans.iter().find(|(n, _, _)| n == nom)
                {
                    let drapeau = if souvenir { "r" } else { "" };
                    println!("[SELECTION]{drapeau}/region:{nom}@{},{},{l},{h}", x - ex, y - ey);
                }
            }
            drop(maintien);
        },
    );
}

#[cfg(test)]
mod essais {
    use super::fenetres_du_portail;

    #[test]
    fn liste_du_portail() {
        let liste =
            "12[HC>]firefox[HT>]Accueil - Mozilla[HE>]100623442173952[HA>]7[HC>]kitty[HT>][HE>]0[HA>]";
        let f = fenetres_du_portail(liste);
        assert_eq!(f.len(), 2);
        assert_eq!((f[0].numero.as_str(), f[0].classe.as_str()), ("12", "firefox"));
        assert_eq!(f[0].titre, "Accueil - Mozilla");
        assert_eq!(f[0].adresse, "0x5b843886e000"); // adresse au format de hyprctl
        assert_eq!(f[1].titre, "");
        assert!(fenetres_du_portail("").is_empty());
    }
}
