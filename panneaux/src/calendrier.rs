//! Agenda : trois vues dans le même cadre, les jours du mois, les 12 mois, 12 années.

use std::cell::Cell;
use std::rc::Rc;

use chrono::{Datelike, Duration, Local, NaiveDate};
use gtk::prelude::*;

use crate::outils::{boite, bouton, bouton_nu, etiquette_centree, icone, vider};

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
const MOIS_COURTS: [&str; 12] =
    ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."];
const JOURS: [&str; 7] = ["lu", "ma", "me", "je", "ve", "sa", "di"];

#[derive(Clone, Copy, PartialEq)]
enum Vue {
    Jours,
    Mois,
    Annees,
}

struct Calendrier {
    an: Cell<i32>,
    mois: Cell<u32>, // 1 à 12
    vue: Cell<Vue>,
    premiere_annee: Cell<i32>, // première année montrée dans la vue "années"
    bouton_mois: gtk::Button,
    bouton_an: gtk::Button,
    zone: gtk::Box,
}

pub fn creer() -> gtk::Box {
    let aujourdhui = Local::now().date_naive();
    let cal = Rc::new(Calendrier {
        an: Cell::new(aujourdhui.year()),
        mois: Cell::new(aujourdhui.month()),
        vue: Cell::new(Vue::Jours),
        premiere_annee: Cell::new(aujourdhui.year() - 5),
        bouton_mois: bouton_nu(&["titre-cal"]),
        bouton_an: bouton_nu(&["titre-cal"]),
        zone: boite(false, 0),
    });
    let racine = boite(true, 8);

    let c = Rc::clone(&cal);
    cal.bouton_mois.connect_clicked(move |_| c.basculer_vue(Vue::Mois));
    let c = Rc::clone(&cal);
    cal.bouton_an.connect_clicked(move |_| c.basculer_vue(Vue::Annees));
    let titre = boite(false, 0);
    titre.append(&cal.bouton_mois);
    titre.append(&cal.bouton_an);

    let entete = gtk::CenterBox::new();
    let c = Rc::clone(&cal);
    entete.set_start_widget(Some(&bouton(icone::PRECEDENT, &[], move || c.decaler(-1))));
    entete.set_center_widget(Some(&titre));
    let c = Rc::clone(&cal);
    entete.set_end_widget(Some(&bouton(icone::SUIVANT, &[], move || c.decaler(1))));
    racine.append(&entete);

    cal.zone.set_size_request(290, 250); // taille fixe : le panneau ne saute pas
    cal.zone.set_vexpand(true);
    racine.append(&cal.zone);
    cal.dessiner();
    racine
}

impl Calendrier {
    /// Flèches : un mois, une année ou une page d'années, selon la vue affichée.
    fn decaler(self: &Rc<Self>, sens: i32) {
        match self.vue.get() {
            Vue::Jours => {
                let numero = self.mois.get() as i32 - 1 + sens; // 0 à 11, peut déborder d'un cran
                self.an.set(self.an.get() + numero.div_euclid(12));
                self.mois.set(numero.rem_euclid(12) as u32 + 1);
            }
            Vue::Mois => self.an.set(self.an.get() + sens),
            Vue::Annees => self.premiere_annee.set(self.premiere_annee.get() + 12 * sens),
        }
        self.dessiner();
    }

    /// Clic sur le mois ou l'année : ouvre la grille de choix, ou revient aux jours.
    fn basculer_vue(self: &Rc<Self>, vue: Vue) {
        self.vue.set(if self.vue.get() == vue { Vue::Jours } else { vue });
        if self.vue.get() == Vue::Annees {
            self.premiere_annee.set(self.an.get() - 5);
        }
        self.dessiner();
    }

    fn dessiner(self: &Rc<Self>) {
        self.bouton_mois.set_label(MOIS[self.mois.get() as usize - 1]);
        self.bouton_an.set_label(&self.an.get().to_string());
        vider(&self.zone);
        let grille = gtk::Grid::new();
        grille.set_column_homogeneous(true);
        grille.set_row_homogeneous(true);
        grille.set_column_spacing(2);
        grille.set_row_spacing(2);
        grille.set_hexpand(true);
        grille.set_vexpand(true);
        match self.vue.get() {
            Vue::Jours => self.remplir_jours(&grille),
            Vue::Mois => {
                let choix: Vec<(String, i32)> =
                    MOIS_COURTS.iter().enumerate().map(|(i, m)| (m.to_string(), i as i32 + 1)).collect();
                let c = Rc::clone(self);
                remplir_choix(&grille, &choix, self.mois.get() as i32, move |mois| {
                    c.mois.set(mois as u32);
                    c.vue.set(Vue::Jours);
                    c.dessiner();
                });
            }
            Vue::Annees => {
                let debut = self.premiere_annee.get();
                let choix: Vec<(String, i32)> = (debut..debut + 12).map(|an| (an.to_string(), an)).collect();
                let c = Rc::clone(self);
                remplir_choix(&grille, &choix, self.an.get(), move |an| {
                    c.an.set(an);
                    c.vue.set(Vue::Jours);
                    c.dessiner();
                });
            }
        }
        self.zone.append(&grille);
    }

    fn remplir_jours(&self, grille: &gtk::Grid) {
        for (colonne, nom) in JOURS.iter().enumerate() {
            grille.attach(&etiquette_centree(nom, &["semaine"]), colonne as i32, 0, 1, 1);
        }
        let Some(premier) = NaiveDate::from_ymd_opt(self.an.get(), self.mois.get(), 1) else {
            return;
        };
        // Toujours 6 lignes, quel que soit le mois, à partir du lundi de la première semaine
        let debut = premier - Duration::days(premier.weekday().num_days_from_monday() as i64);
        let aujourdhui = Local::now().date_naive();
        for case in 0..42 {
            let jour = debut + Duration::days(case);
            let mut classes = vec!["jour"];
            if jour.month() != self.mois.get() {
                classes.push("hors"); // jour du mois d'avant ou d'après : grisé
            }
            if jour == aujourdhui {
                classes.push("auj");
            }
            // Un bouton (sans action) plutôt qu'un simple texte : il réagit au survol.
            let b = bouton_nu(&classes);
            b.set_label(&jour.day().to_string());
            grille.attach(&b, (case % 7) as i32, (case / 7 + 1) as i32, 1, 1);
        }
    }
}

/// Grille de 3 colonnes de boutons (mois ou années).
fn remplir_choix(
    grille: &gtk::Grid,
    choix: &[(String, i32)],
    actuel: i32,
    action: impl Fn(i32) + Clone + 'static,
) {
    for (position, (texte, valeur)) in choix.iter().enumerate() {
        let classes: &[&str] = if *valeur == actuel { &["choisi"] } else { &[] };
        let (action, valeur) = (action.clone(), *valeur);
        let b = bouton(texte, classes, move || action(valeur));
        grille.attach(&b, (position % 3) as i32, (position / 3) as i32, 1, 1);
    }
}
