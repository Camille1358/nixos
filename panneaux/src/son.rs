//! Son : volume de la sortie et du micro, choix de la sortie, volume par application.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use serde_json::Value;

use crate::App;
use crate::outils::{
    boite, bouton, bouton_icone, couper, etiquette, executer, icone, lancer, separateur, vider,
};

/// Interroge le serveur de son. Renvoie le texte affiché par pactl.
fn pactl(arguments: &[&str]) -> String {
    let mut commande = vec!["pactl"];
    commande.extend_from_slice(arguments);
    executer(&commande).1
}

/// Liste des "sinks" (sorties), "sources" (entrées) ou "sink-inputs" (applications).
fn pactl_liste(quoi: &str) -> Vec<Value> {
    serde_json::from_str(&pactl(&["-f", "json", "list", quoi])).unwrap_or_default()
}

/// Volume en pourcentage d'une sortie, d'un micro ou d'une application (premier canal).
fn volume_de(element: &Value) -> i32 {
    element["volume"]
        .as_object()
        .and_then(|canaux| canaux.values().next())
        .and_then(|canal| canal["value_percent"].as_str())
        .and_then(|texte| texte.trim().trim_end_matches('%').parse().ok())
        .unwrap_or(0)
}

struct Son {
    app: App,
    racine: gtk::Box,
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 4);
    racine.set_size_request(400, -1);
    let son = Rc::new(Son { app: Rc::clone(app), racine: racine.clone() });
    son.construire();
    racine
}

impl Son {
    fn construire(self: &Rc<Self>) {
        vider(&self.racine);
        self.partie_sortie();
        self.partie_micro();
        self.partie_applications();
        self.racine.append(&separateur());
        let s = Rc::clone(self);
        self.racine.append(&bouton_icone(icone::REGLAGES, "Mélangeur complet", 0, &[], move || {
            s.app.fermer();
            lancer(&["pavucontrol"]);
        }));
    }

    fn partie_sortie(self: &Rc<Self>) {
        let sorties = pactl_liste("sinks");
        let nom_actuel = pactl(&["get-default-sink"]).trim().to_owned();
        self.racine.append(&etiquette("SORTIE", &["titre"]));
        if let Some(actuelle) = sorties.iter().find(|s| s["name"].as_str() == Some(&nom_actuel)) {
            let s = Rc::clone(self);
            self.racine.append(&self.ligne_volume(
                actuelle,
                (icone::SON, icone::SON_COUPE),
                Rc::new(|v| lancer(&["pactl", "set-sink-volume", "@DEFAULT_SINK@", &format!("{v}%")])),
                Rc::new(move || s.pactl_puis_redessiner(&["set-sink-mute", "@DEFAULT_SINK@", "toggle"])),
            ));
        }
        // Choix de la sortie : casque, enceintes, écran...
        for sortie in &sorties {
            let nom = sortie["name"].as_str().unwrap_or("?").to_owned();
            let description = match sortie["description"].as_str() {
                Some(d) if !d.is_empty() && d != "(null)" => d.to_owned(),
                _ => nom.clone(),
            };
            let choisie = nom == nom_actuel;
            let s = Rc::clone(self);
            self.racine.append(&bouton_icone(
                if choisie { icone::COCHE } else { " " },
                &description,
                38,
                if choisie { &["choisi"] } else { &[] },
                move || s.pactl_puis_redessiner(&["set-default-sink", &nom]),
            ));
        }
    }

    fn partie_micro(self: &Rc<Self>) {
        let nom_actuel = pactl(&["get-default-source"]).trim().to_owned();
        let sources = pactl_liste("sources");
        let Some(micro) = sources.iter().find(|s| s["name"].as_str() == Some(&nom_actuel)) else {
            return;
        };
        self.racine.append(&separateur());
        self.racine.append(&etiquette("MICRO", &["titre"]));
        let s = Rc::clone(self);
        self.racine.append(&self.ligne_volume(
            micro,
            (icone::MICRO, icone::MICRO_COUPE),
            Rc::new(|v| lancer(&["pactl", "set-source-volume", "@DEFAULT_SOURCE@", &format!("{v}%")])),
            Rc::new(move || s.pactl_puis_redessiner(&["set-source-mute", "@DEFAULT_SOURCE@", "toggle"])),
        ));
    }

    fn partie_applications(self: &Rc<Self>) {
        let applis = pactl_liste("sink-inputs");
        if applis.is_empty() {
            return;
        }
        self.racine.append(&separateur());
        self.racine.append(&etiquette("APPLICATIONS", &["titre"]));
        for appli in &applis {
            let numero = appli["index"].to_string();
            let infos = &appli["properties"];
            let nom = [&infos["application.name"], &infos["media.name"]]
                .iter()
                .find_map(|v| v.as_str().filter(|t| !t.is_empty()))
                .unwrap_or("?");
            let e = etiquette(nom, &[]);
            couper(&e, 40);
            e.set_margin_start(10);
            self.racine.append(&e);
            let (s, n) = (Rc::clone(self), numero.clone());
            self.racine.append(&self.ligne_volume(
                appli,
                (icone::SON, icone::SON_COUPE),
                Rc::new(move |v| lancer(&["pactl", "set-sink-input-volume", &numero, &format!("{v}%")])),
                Rc::new(move || s.pactl_puis_redessiner(&["set-sink-input-mute", &n, "toggle"])),
            ));
        }
    }

    /// Une ligne : bouton couper/rétablir, curseur de volume, pourcentage.
    fn ligne_volume(
        &self,
        element: &Value,
        icones: (&str, &str),
        regler: Rc<dyn Fn(i32)>,
        couper_son: Rc<dyn Fn()>,
    ) -> gtk::Box {
        let coupe = element["mute"].as_bool().unwrap_or(false);
        let valeur = volume_de(element).min(100);

        let curseur = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 100.0, 1.0);
        curseur.set_value(valeur as f64);
        curseur.set_hexpand(true);
        curseur.set_draw_value(false);
        let pourcent = etiquette(&format!("{valeur} %"), &["discret"]);
        pourcent.set_width_chars(5);
        pourcent.set_xalign(1.0);

        // Pendant qu'on fait glisser le curseur, il change des dizaines de fois par
        // seconde : on n'envoie le volume au système qu'une fois toutes les 40 ms.
        let en_attente = Rc::new(Cell::new(false));
        let p = pourcent.clone();
        curseur.connect_value_changed(move |curseur| {
            p.set_text(&format!("{} %", curseur.value() as i32));
            if !en_attente.get() {
                en_attente.set(true);
                let (attente, regler, c) = (Rc::clone(&en_attente), Rc::clone(&regler), curseur.clone());
                glib::timeout_add_local_once(Duration::from_millis(40), move || {
                    attente.set(false);
                    regler(c.value() as i32);
                });
            }
        });

        let ligne = boite(false, 4);
        let icone = if coupe { icones.1 } else { icones.0 };
        ligne.append(&bouton(icone, if coupe { &["danger"] } else { &[] }, move || couper_son()));
        ligne.append(&curseur);
        ligne.append(&pourcent);
        ligne
    }

    fn pactl_puis_redessiner(self: &Rc<Self>, arguments: &[&str]) {
        pactl(arguments);
        self.construire();
    }
}
