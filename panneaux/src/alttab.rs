//! Alt+Tab : miniatures des fenêtres.
//!
//! La logique (ordre des fenêtres, Tab, relâchement d'Alt) est dans Hyprland
//! (desktop-home.nix, "AltTab"), pour rester instantanée même en tapotant vite. Hyprland
//! écrit l'adresse de la fenêtre choisie dans un petit fichier, que ce panneau suit
//! pour encadrer la bonne miniature ; il y écrit "fin" quand le choix est terminé.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use serde_json::Value;

use crate::App;
use crate::outils::{
    boite, couper, dossier_session, en_fond, etiquette, etiquette_centree, executer, executer_delai, miniature_grim,
    hyprland, icone, icone_appli, image_ajustee, marges,
};

const LARGEUR: i32 = 260; // taille d'une miniature
const HAUTEUR: i32 = 165;
const PAR_LIGNE: usize = 5;

fn fichier_choix() -> PathBuf {
    dossier_session().join("alttab-choix")
}

/// Adresse de la fenêtre choisie, ou None si le choix est terminé (ou annulé).
pub fn choix_en_cours() -> Option<String> {
    let choix = std::fs::read_to_string(fichier_choix()).ok()?.trim().to_owned();
    (!choix.is_empty() && choix != "fin").then_some(choix)
}

struct AltTab {
    app: App,
    numero: u64,
    cartes: HashMap<String, gtk::Box>, // adresse -> carte
    choix: RefCell<Option<String>>,
    minuteur: RefCell<Option<glib::SourceId>>,
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 0);
    // Toutes les fenêtres (fenêtres réduites comprises), de la plus récemment utilisée
    // à la plus ancienne
    let mut fenetres: Vec<Value> = match hyprland("clients") {
        Value::Array(liste) => liste
            .into_iter()
            .filter(|f| {
                let espace = f["workspace"]["name"].as_str().unwrap_or_default();
                f["mapped"].as_bool().unwrap_or(true)
                    && (espace == "special:reduites" || !espace.starts_with("special:"))
            })
            .collect(),
        _ => Vec::new(),
    };
    fenetres.sort_by_key(|f| f["focusHistoryID"].as_i64().unwrap_or(99));

    let grille = gtk::Grid::new();
    grille.set_column_spacing(12);
    grille.set_row_spacing(12);
    let mut cartes = HashMap::new();
    let mut cadres = Vec::new();
    for (i, f) in fenetres.iter().enumerate() {
        let (carte, cadre) = carte(app, f);
        grille.attach(&carte, (i % PAR_LIGNE) as i32, (i / PAR_LIGNE) as i32, 1, 1);
        cartes.insert(f["address"].as_str().unwrap_or_default().to_owned(), carte);
        cadres.push(cadre);
    }
    racine.append(&grille);

    let alttab = Rc::new(AltTab {
        app: Rc::clone(app),
        numero: app.numero(),
        cartes,
        choix: RefCell::new(None),
        minuteur: RefCell::new(None),
    });
    let dossier = dossier_session().join("alttab-miniatures");
    let _ = std::fs::create_dir_all(&dossier);
    for (f, cadre) in fenetres.iter().zip(cadres) {
        alttab.miniature(f, cadre, &dossier);
    }

    if alttab.suivre() {
        let a = Rc::clone(&alttab);
        let minuteur = glib::timeout_add_local(Duration::from_millis(30), move || {
            if a.suivre() { glib::ControlFlow::Continue } else { glib::ControlFlow::Break }
        });
        alttab.minuteur.replace(Some(minuteur));
        let a = Rc::clone(&alttab);
        app.quand_fermer(move || {
            if let Some(m) = a.minuteur.take() {
                m.remove();
            }
        });
    }
    racine
}

/// Une carte : la miniature (l'icône de l'application en attendant), puis le titre.
fn carte(app: &App, f: &Value) -> (gtk::Box, gtk::CenterBox) {
    let classe = f["class"].as_str().unwrap_or_default();
    let zone = boite(true, 8);
    marges(&zone, 10);
    let cadre = gtk::CenterBox::new();
    cadre.set_size_request(LARGEUR, HAUTEUR);
    cadre.add_css_class("miniature");
    match icone_appli(classe, 64) {
        Some(image) => cadre.set_center_widget(Some(&image)),
        None => cadre.set_center_widget(Some(&etiquette_centree(icone::FENETRE, &["grosse-icone"]))),
    }
    zone.append(&cadre);

    let titre = boite(false, 6);
    if let Some(petite) = icone_appli(classe, 18) {
        titre.append(&petite);
    }
    let texte =
        [&f["title"], &f["class"]].iter().find_map(|v| v.as_str().filter(|t| !t.is_empty())).unwrap_or("?");
    let e = etiquette(texte, &[]);
    couper(&e, 26);
    e.set_hexpand(true);
    titre.append(&e);
    zone.append(&titre);

    zone.add_css_class("carte");
    let clic = gtk::GestureClick::new();
    clic.set_button(0);
    let (app, adresse) = (Rc::clone(app), f["address"].as_str().unwrap_or_default().to_owned());
    clic.connect_pressed(move |_, _, _, _| {
        executer(&["hyprctl", "eval", &format!("AltTab.choisir(\"{adresse}\")")]);
        app.fermer();
    });
    zone.add_controller(clic);
    (zone, cadre)
}

impl AltTab {
    /// Capture la fenêtre (même cachée ou sur un autre bureau), sans figer l'affichage.
    fn miniature(self: &Rc<Self>, f: &Value, cadre: gtk::CenterBox, dossier: &std::path::Path) {
        let ident = f["stableId"].to_string().trim_matches('"').to_owned();
        let chemin = dossier.join(format!("{ident}.jpg"));
        let c = chemin.clone();
        let a = Rc::clone(self);
        en_fond(
            move || {
                miniature_grim(&["-T", &ident], &c.to_string_lossy())
            },
            move |reussi| {
                if reussi {
                    let image = image_ajustee(&chemin, LARGEUR, HAUTEUR, true);
                    if let (Some((image, _, _)), true) = (image, a.app.affiche(a.numero)) {
                        cadre.set_center_widget(Some(&image));
                    }
                }
                let _ = std::fs::remove_file(&chemin);
            },
        );
    }

    /// Suit le choix fait dans Hyprland. Renvoie false quand le choix est terminé.
    fn suivre(&self) -> bool {
        let Some(choix) = choix_en_cours() else {
            // choix terminé (ou annulé) dans Hyprland : le minuteur s'arrête de lui-même
            self.minuteur.take();
            self.app.fermer();
            return false;
        };
        if self.choix.borrow().as_deref() != Some(choix.as_str()) {
            for (adresse, carte) in &self.cartes {
                if *adresse == choix {
                    carte.add_css_class("choisie");
                } else {
                    carte.remove_css_class("choisie");
                }
            }
            self.choix.replace(Some(choix));
        }
        true
    }
}
