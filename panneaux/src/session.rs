//! Menu session : éteindre, redémarrer, veille, arrêt programmé, veille automatique,
//! verrouiller, déconnexion.

use std::rc::Rc;
use std::sync::LazyLock;

use chrono::{Duration, Local, NaiveDate, NaiveDateTime, NaiveTime};
use gtk::prelude::*;
use regex::Regex;

use crate::App;
use crate::outils::{
    arret_prevu, boite, bouton_icone, drapeau_veille, etiquette, executer, icone, lancer, notifier,
    rafraichir_barre, separateur, vider,
};
use crate::style::THEME;

// Formes de date et d'heure comprises (préparées une seule fois)
static DEMAIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(apr[eè]s-demain|demain)\s+(.*)$").unwrap());
static ISO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d{4})-(\d{1,2})-(\d{1,2})\s+(.*)$").unwrap());
static FRANCAISE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\s+(.*)$").unwrap());
static HEURE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d{1,2})\s*(?:[:h]\s*(\d{2})?)?$").unwrap());

/// Transforme le texte tapé en date et heure, ou None si ce n'est pas compris.
///
/// Formes acceptées : "23:30", "7h30", "7h", "90" (dans 90 minutes),
/// "demain 7:00", "après-demain 9h", "24/12 18:00", "2026-12-24 18:00".
pub fn analyser_moment(saisie: &str, maintenant: NaiveDateTime) -> Option<NaiveDateTime> {
    let minuscules = saisie.trim().to_lowercase();
    let mut texte = minuscules.as_str();
    if !texte.is_empty() && texte.chars().all(|c| c.is_ascii_digit()) {
        return Some(maintenant + Duration::minutes(texte.parse().ok()?));
    }

    let mut jour: Option<NaiveDate> = None; // date précise, si elle est donnée
    let mut dans_jours = 0; // sinon : 0 = aujourd'hui, 1 = demain, 2 = après-demain

    if let Some(m) = DEMAIN.captures(texte) {
        dans_jours = if m[1].starts_with("apr") { 2 } else { 1 };
        texte = m.get(2).unwrap().as_str();
    }

    if let Some(m) = ISO.captures(texte) {
        jour = Some(NaiveDate::from_ymd_opt(m[1].parse().ok()?, m[2].parse().ok()?, m[3].parse().ok()?)?);
        texte = m.get(4).unwrap().as_str();
    } else if let Some(m) = FRANCAISE.captures(texte) {
        let an = match m.get(3) {
            Some(a) => a.as_str().parse().ok()?,
            None => chrono::Datelike::year(&maintenant),
        };
        jour = Some(NaiveDate::from_ymd_opt(an, m[2].parse().ok()?, m[1].parse().ok()?)?);
        texte = m.get(4).unwrap().as_str();
    }

    // 23:30, 7h30, 7h, 7
    let m = HEURE.captures(texte)?;
    let minutes = m.get(2).map_or(Some(0), |x| x.as_str().parse().ok())?;
    let heure = NaiveTime::from_hms_opt(m[1].parse().ok()?, minutes, 0)?;
    let date_seule = jour.is_none() && dans_jours == 0;
    let jour = jour.unwrap_or_else(|| maintenant.date() + Duration::days(dans_jours));
    let mut moment = jour.and_time(heure);
    if date_seule && moment <= maintenant {
        moment += Duration::days(1); // une heure déjà passée aujourd'hui = demain
    }
    (moment > maintenant).then_some(moment)
}

struct Session {
    app: App,
    racine: gtk::Box,
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 2);
    racine.set_size_request(320, -1);
    let session = Rc::new(Session { app: Rc::clone(app), racine: racine.clone() });
    session.construire();
    racine
}

impl Session {
    fn construire(self: &Rc<Self>) {
        let r = &self.racine;
        vider(r);
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::ETEINDRE, "Éteindre", 0, &["danger"], move || {
            s.quitter_et_lancer(&["systemctl", "poweroff"])
        }));
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::REDEMARRER, "Redémarrer", 0, &[], move || {
            s.quitter_et_lancer(&["systemctl", "reboot"])
        }));
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::VEILLE, "Mettre en veille", 0, &[], move || {
            s.quitter_et_lancer(&["systemctl", "suspend"])
        }));
        r.append(&separateur());

        if let Some(prevu) = arret_prevu() {
            let s = Rc::clone(self);
            let texte = format!("Annuler l'arrêt de {}", prevu.format("%H:%M"));
            r.append(&bouton_icone(icone::ANNULER, &texte, 0, &[], move || s.annuler_arret()));
        } else {
            let (revelateur, saisie) = self.zone_de_saisie();
            let (rv, sa) = (revelateur.clone(), saisie);
            r.append(&bouton_icone(icone::SABLIER, "Programmer un arrêt…", 0, &[], move || {
                let ouvert = !rv.reveals_child();
                rv.set_reveal_child(ouvert);
                if ouvert {
                    sa.grab_focus();
                }
            }));
            r.append(&revelateur);
        }

        let s = Rc::clone(self);
        if drapeau_veille().exists() {
            r.append(&bouton_icone(
                icone::CAFE,
                "Veille auto de l'ordi : désactivée",
                0,
                &["choisi"],
                move || s.basculer_veille(),
            ));
        } else {
            r.append(&bouton_icone(icone::LIT, "Veille auto de l'ordi : activée", 0, &[], move || {
                s.basculer_veille()
            }));
        }
        r.append(&separateur());
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::CADENAS, "Verrouiller", 0, &[], move || {
            s.quitter_et_lancer(&["hyprlock"])
        }));
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::SORTIR, "Déconnexion", 0, &[], move || {
            s.quitter_et_lancer(&["hyprctl", "dispatch", "hl.dsp.exit()"])
        }));
    }

    /// Champ "éteindre à", caché tant qu'on n'a pas cliqué sur "Programmer un arrêt".
    fn zone_de_saisie(self: &Rc<Self>) -> (gtk::Revealer, gtk::Entry) {
        let saisie = gtk::Entry::new();
        saisie.set_placeholder_text(Some("23:30  ·  90  ·  demain 7:00"));
        let aide = etiquette("Heure, minutes, ou date : 24/12 18:00", &["discret"]);
        let s = Rc::clone(self);
        let a = aide.clone();
        saisie.connect_activate(move |champ| s.programmer_arret(&champ.text(), &a)); // touche Entrée
        let zone = boite(true, 4);
        zone.set_margin_start(42);
        zone.set_margin_end(6);
        zone.set_margin_bottom(6);
        zone.append(&saisie);
        zone.append(&aide);
        let revelateur = gtk::Revealer::new();
        revelateur.set_child(Some(&zone));
        (revelateur, saisie)
    }

    fn quitter_et_lancer(&self, commande: &[&str]) {
        self.app.fermer();
        lancer(commande);
    }

    fn programmer_arret(&self, texte: &str, aide: &gtk::Label) {
        let Some(moment) = analyser_moment(texte, Local::now().naive_local()) else {
            aide.set_text("Pas compris, ou déjà passé. Exemple : 23:30");
            aide.add_css_class("erreur");
            return;
        };
        let quand = format!("--when={}", moment.format("%Y-%m-%d %H:%M:%S"));
        let (reussi, _) = executer(&["systemctl", "poweroff", "--no-wall", &quand]);
        if reussi {
            let texte = format!("L'ordinateur s'éteindra le {}.", moment.format("%d/%m à %H:%M"));
            notifier("Arrêt programmé", &texte, false);
        } else {
            notifier("Arrêt programmé", "Impossible de programmer l'arrêt.", true);
        }
        rafraichir_barre(8); // témoin de la barre (tasse de café, sablier)
        self.app.fermer();
    }

    fn annuler_arret(self: &Rc<Self>) {
        executer(&["systemctl", "poweroff", "--no-wall", "--when=cancel"]);
        notifier("Arrêt programmé", "Arrêt annulé.", false);
        rafraichir_barre(8);
        self.construire();
    }

    fn basculer_veille(self: &Rc<Self>) {
        let drapeau = drapeau_veille();
        if drapeau.exists() {
            let _ = std::fs::remove_file(&drapeau);
            let texte = format!("Réactivée : veille après {} min d'inactivité.", THEME.ordi_en_veille_apres);
            notifier("Veille automatique", &texte, false);
        } else {
            let _ = std::fs::write(&drapeau, ""); // fichier vide : seule sa présence compte
            notifier(
                "Veille automatique",
                "Désactivée : l'ordinateur reste allumé (l'écran s'éteint toujours).",
                false,
            );
        }
        rafraichir_barre(8);
        self.construire();
    }
}

#[cfg(test)]
mod essais {
    use super::*;

    fn a(texte: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(texte, "%Y-%m-%d %H:%M").unwrap()
    }

    #[test]
    fn moments() {
        let maintenant = a("2026-10-15 14:00");
        let cas = [
            ("23:30", Some("2026-10-15 23:30")),
            ("7h30", Some("2026-10-16 07:30")), // déjà passé aujourd'hui : demain
            ("7h", Some("2026-10-16 07:00")),
            ("15", Some("2026-10-15 14:15")), // 15 minutes
            ("demain 7:00", Some("2026-10-16 07:00")),
            ("après-demain 9h", Some("2026-10-17 09:00")),
            ("apres-demain 9h", Some("2026-10-17 09:00")),
            ("24/12 18:00", Some("2026-12-24 18:00")),
            ("24/12/2027 18:00", Some("2027-12-24 18:00")),
            ("2026-12-24 18:00", Some("2026-12-24 18:00")),
            ("  Demain 7H05 ", Some("2026-10-16 07:05")),
            ("25:00", None),
            ("31/02 10:00", None),
            ("01/01 10:00", None), // déjà passé
            ("bonjour", None),
            ("", None),
        ];
        for (saisie, attendu) in cas {
            assert_eq!(analyser_moment(saisie, maintenant), attendu.map(a), "saisie : {saisie:?}");
        }
    }
}
