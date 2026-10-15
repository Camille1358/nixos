//! Fenêtres réduites (bouton "réduire" des fenêtres, ou Super+N).

use std::rc::Rc;

use gtk::prelude::*;
use serde_json::Value;

use crate::App;
use crate::outils::{
    boite, bouton_icone, etiquette, executer, hyprland, icone, rafraichir_barre, separateur,
};

const ESPACE_REDUITES: &str = "special:reduites";

/// Adresse et titre des fenêtres réduites.
pub fn fenetres_reduites() -> Vec<Value> {
    match hyprland("clients") {
        Value::Array(fenetres) => fenetres
            .into_iter()
            .filter(|f| f["workspace"]["name"].as_str() == Some(ESPACE_REDUITES))
            .collect(),
        _ => Vec::new(),
    }
}

/// Ramène la fenêtre sur l'espace de travail affiché et lui donne la main.
pub fn ramener(fenetre: &Value) {
    let adresse = fenetre["address"].as_str().unwrap_or_default();
    let actif = hyprland("activeworkspace")["id"].as_i64().unwrap_or(1);
    executer(&[
        "hyprctl",
        "dispatch",
        &format!("hl.dsp.window.move({{ window = \"address:{adresse}\", workspace = {actif} }})"),
    ]);
    executer(&["hyprctl", "dispatch", &format!("hl.dsp.focus({{ window = \"address:{adresse}\" }})")]);
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 2);
    racine.set_size_request(340, -1);
    let fenetres = fenetres_reduites();
    racine.append(&etiquette("FENÊTRES RÉDUITES", &["titre"]));
    if fenetres.is_empty() {
        racine.append(&etiquette("Aucune. Bouton « réduire » d'une fenêtre, ou Super+N.", &["discret"]));
    }
    for f in &fenetres {
        let texte = [&f["title"], &f["class"]]
            .iter()
            .find_map(|v| v.as_str().filter(|t| !t.is_empty()))
            .unwrap_or("?")
            .to_owned();
        let (app, f) = (Rc::clone(app), f.clone());
        racine.append(&bouton_icone(icone::FENETRE, &texte, 40, &[], move || {
            app.fermer();
            ramener(&f);
            rafraichir_barre(9);
        }));
    }
    if fenetres.len() > 1 {
        racine.append(&separateur());
        let app = Rc::clone(app);
        racine.append(&bouton_icone(icone::TOUT, "Tout ramener", 0, &[], move || {
            app.fermer();
            for f in fenetres_reduites() {
                ramener(&f);
            }
            rafraichir_barre(9);
        }));
    }
    racine
}
