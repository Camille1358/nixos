//! Notifications (cloche de la barre) : historique groupé par application, et
//! "Ne pas déranger" pour une durée choisie.
//!
//! Le journal est rempli par le service "journal-notifications" (startup.nix), qui note
//! chaque notification avec sa date et son heure, une par ligne.

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use chrono::{DateTime, Duration, Local, TimeZone};
use gtk::pango;
use gtk::prelude::*;
use regex::Regex;
use serde_json::Value;

use crate::outils::{
    boite, bouton, bouton_icone, chercher_programme, couper, dossier_etat, etiquette, etiquette_centree,
    executer, icone, icone_appli, rafraichir_barre, separateur, vider,
};

const NOTIFS_GARDEES: usize = 300;
const PAR_APPLI: usize = 5; // notifications affichées par application (les plus récentes)

fn dossier() -> PathBuf {
    dossier_etat().join("notifications")
}
fn journal() -> PathBuf {
    dossier().join("journal.jsonl")
}
/// Date de la dernière ouverture du panneau
fn vu() -> PathBuf {
    dossier().join("vu")
}

fn ecrire_notifications(notifications: &[Value]) {
    let _ = std::fs::create_dir_all(dossier());
    let mut texte = String::new();
    for n in notifications {
        texte.push_str(&n.to_string());
        texte.push('\n');
    }
    // Écrit à côté puis remplacé d'un coup : le journal n'est jamais à moitié écrit
    let provisoire = dossier().join("journal.jsonl.tmp");
    if std::fs::write(&provisoire, texte).is_ok() {
        let _ = std::fs::rename(&provisoire, journal());
    }
}

fn lire_notifications() -> Vec<Value> {
    let Ok(texte) = std::fs::read_to_string(journal()) else {
        return Vec::new();
    };
    let mut notifications: Vec<Value> = texte.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    if notifications.len() > NOTIFS_GARDEES * 2 {
        // le journal ne grossit pas sans fin
        notifications.drain(..notifications.len() - NOTIFS_GARDEES);
        ecrire_notifications(&notifications);
    }
    notifications
}

/// Texte brut : sans les balises de mise en forme (<b>...) ni les codes HTML (&amp;).
pub fn sans_balises(texte: &str) -> String {
    let balise = Regex::new(r"<[^>]*>").unwrap();
    let sans = balise.replace_all(texte, "");
    let code = Regex::new(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);").unwrap();
    code.replace_all(&sans, |m: &regex::Captures| {
        let nom = &m[1];
        let lettre = if let Some(hexa) = nom.strip_prefix("#x").or_else(|| nom.strip_prefix("#X")) {
            u32::from_str_radix(hexa, 16).ok().and_then(char::from_u32)
        } else if let Some(nombre) = nom.strip_prefix('#') {
            nombre.parse().ok().and_then(char::from_u32)
        } else {
            match nom {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => None,
            }
        };
        lettre.map_or_else(|| m[0].to_owned(), String::from)
    })
    .trim()
    .to_owned()
}

fn ne_pas_deranger() -> bool {
    executer(&["makoctl", "mode"]).1.split_whitespace().any(|m| m == "do-not-disturb")
}

// "Ne pas déranger" pour une durée choisie : un minuteur systemd le désactive à l'heure dite
// (sur l'horloge réelle : il se déclenche aussi si l'ordinateur était en veille à ce moment-là).
// L'heure de fin est notée dans un fichier, pour l'afficher dans le panneau.
const MINUTEUR_DND: &str = "fin-ne-pas-deranger";
const DND_MATIN: u32 = 8; // "jusqu'à demain matin" = demain à cette heure-là

fn fin_dnd() -> PathBuf {
    dossier().join("ne-pas-deranger-fin")
}

/// Heure de fin du "Ne pas déranger", ou None s'il dure jusqu'à désactivation.
fn fin_ne_pas_deranger() -> Option<DateTime<Local>> {
    let secondes: i64 = std::fs::read_to_string(fin_dnd()).ok()?.trim().parse().ok()?;
    Local.timestamp_opt(secondes, 0).single().filter(|fin| *fin > Local::now())
}

fn demain_matin() -> DateTime<Local> {
    let demain = (Local::now() + Duration::days(1)).date_naive();
    let moment = demain.and_hms_opt(DND_MATIN, 0, 0).expect("heure valide");
    Local.from_local_datetime(&moment).earliest().unwrap_or_else(|| Local::now() + Duration::days(1))
}

fn date_de(n: &Value) -> DateTime<Local> {
    Local.timestamp_opt(n["t"].as_i64().unwrap_or(0), 0).single().unwrap_or_default()
}

fn appli_de(n: &Value) -> String {
    n["app"].as_str().filter(|a| !a.is_empty()).unwrap_or("Système").to_owned()
}

struct Notifications {
    racine: gtk::Box,
    choix_duree: Cell<bool>, // la rangée "pendant combien de temps ?" est-elle ouverte
}

pub fn creer() -> gtk::Box {
    let racine = boite(true, 6);
    racine.set_size_request(450, -1);
    let n = Rc::new(Notifications { racine: racine.clone(), choix_duree: Cell::new(false) });
    n.construire();
    // Tout est maintenant "vu" : la cloche de la barre ne sonne plus
    let _ = std::fs::create_dir_all(dossier());
    let _ = std::fs::write(vu(), Local::now().timestamp().to_string());
    rafraichir_barre(10);
    racine
}

impl Notifications {
    fn construire(self: &Rc<Self>) {
        let r = &self.racine;
        vider(r);
        let dnd = ne_pas_deranger();
        let entete = boite(false, 6);
        let titre = etiquette("NOTIFICATIONS", &["titre"]);
        titre.set_hexpand(true);
        entete.append(&titre);
        let s = Rc::clone(self);
        entete.append(&bouton_icone(
            if dnd { icone::CLOCHE_BARREE } else { icone::CLOCHE },
            "Ne pas déranger",
            0,
            if dnd { &["choisi"] } else { &[] },
            move || s.basculer_ne_pas_deranger(),
        ));
        r.append(&entete);

        if dnd {
            // rappel : jusqu'à quand
            let quand = match fin_ne_pas_deranger() {
                None => "jusqu'à ce que tu le désactives".to_owned(),
                Some(fin) if fin.date_naive() == Local::now().date_naive() => {
                    format!("jusqu'à {}", fin.format("%H:%M"))
                }
                Some(fin) => format!("jusqu'à demain {}", fin.format("%H:%M")),
            };
            r.append(&etiquette(&format!("Ne pas déranger activé, {quand}."), &["discret"]));
        } else if self.choix_duree.get() {
            // pendant combien de temps ?
            r.append(&etiquette("Ne pas déranger pendant :", &["discret"]));
            let durees = boite(false, 4);
            let maintenant = Local::now();
            for (texte, fin) in [
                ("1 heure", Some(maintenant + Duration::hours(1))),
                ("4 heures", Some(maintenant + Duration::hours(4))),
                ("Jusqu'à demain", Some(demain_matin())),
                ("Toujours", None),
            ] {
                let s = Rc::clone(self);
                durees.append(&bouton(texte, &[], move || s.activer_ne_pas_deranger(fin)));
            }
            r.append(&durees);
        }

        let mut notifications = lire_notifications();
        if notifications.is_empty() {
            r.append(&etiquette("Aucune notification.", &["discret"]));
            return;
        }
        // Application -> ses notifications, la plus récente d'abord ; les applications
        // dans l'ordre de leur notification la plus récente
        notifications.sort_by_key(|n| std::cmp::Reverse(n["t"].as_i64().unwrap_or(0)));
        let mut groupes: Vec<(String, Vec<&Value>)> = Vec::new();
        for n in &notifications {
            let appli = appli_de(n);
            match groupes.iter_mut().find(|(a, _)| *a == appli) {
                Some((_, elles)) => elles.push(n),
                None => groupes.push((appli, vec![n])),
            }
        }

        let liste = boite(true, 4);
        for (appli, elles) in &groupes {
            liste.append(&self.entete_appli(appli));
            for n in elles.iter().take(PAR_APPLI) {
                liste.append(&notification(n));
            }
            if elles.len() > PAR_APPLI {
                let reste =
                    etiquette(&format!("… et {} plus anciennes", elles.len() - PAR_APPLI), &["discret"]);
                reste.set_margin_start(30);
                liste.append(&reste);
            }
        }
        // Liste à sa taille naturelle ; au-delà de 620 pixels de haut, elle défile.
        let defilement = gtk::ScrolledWindow::new();
        defilement.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
        defilement.set_propagate_natural_height(true);
        defilement.set_max_content_height(620);
        defilement.set_child(Some(&liste));
        r.append(&defilement);
        r.append(&separateur());
        let s = Rc::clone(self);
        r.append(&bouton_icone(icone::POUBELLE, "Tout effacer", 0, &["danger"], move || {
            ecrire_notifications(&[]);
            executer(&["makoctl", "dismiss", "--all"]);
            s.construire();
        }));
    }

    fn entete_appli(self: &Rc<Self>, appli: &str) -> gtk::Box {
        let rangee = boite(false, 8);
        rangee.set_margin_top(6);
        let image = if appli == "Système" { None } else { icone_appli(appli, 20) };
        match image {
            Some(image) => rangee.append(&image),
            None => rangee.append(&etiquette_centree(icone::CLOCHE, &["icone"])),
        }
        let nom = etiquette(appli, &["appli"]);
        couper(&nom, 32);
        nom.set_hexpand(true);
        rangee.append(&nom);
        let (s, a) = (Rc::clone(self), appli.to_owned());
        let effacer = bouton(icone::ANNULER, &["petit"], move || {
            let restantes: Vec<Value> =
                lire_notifications().into_iter().filter(|n| appli_de(n) != a).collect();
            ecrire_notifications(&restantes);
            s.construire();
        });
        effacer.set_tooltip_text(Some(&format!("Effacer les notifications de {appli}")));
        rangee.append(&effacer);
        rangee
    }

    /// Activé : le désactiver. Désactivé : demander pendant combien de temps.
    fn basculer_ne_pas_deranger(self: &Rc<Self>) {
        if ne_pas_deranger() {
            arreter_minuteur();
            executer(&["makoctl", "mode", "-r", "do-not-disturb"]);
            rafraichir_barre(10);
        } else {
            self.choix_duree.set(!self.choix_duree.get());
        }
        self.construire();
    }

    /// fin = moment de fin, ou None pour "jusqu'à désactivation".
    fn activer_ne_pas_deranger(self: &Rc<Self>, fin: Option<DateTime<Local>>) {
        arreter_minuteur();
        executer(&["makoctl", "mode", "-a", "do-not-disturb"]);
        if let Some(fin) = fin {
            let _ = std::fs::write(fin_dnd(), fin.timestamp().to_string());
            // Chemins complets : le minuteur ne connaît pas le PATH du panneau
            let chemin = |nom: &str| {
                chercher_programme(nom).map_or(nom.to_owned(), |p| p.to_string_lossy().into_owned())
            };
            let fin_mode =
                format!("{} mode -r do-not-disturb; {} -RTMIN+10 waybar", chemin("makoctl"), chemin("pkill"));
            executer(&[
                "systemd-run",
                "--user",
                "--collect",
                &format!("--unit={MINUTEUR_DND}"),
                &format!("--on-calendar={}", fin.format("%Y-%m-%d %H:%M:%S")),
                "--timer-property=AccuracySec=1s",
                &chemin("sh"),
                "-c",
                &fin_mode,
            ]);
        }
        self.choix_duree.set(false);
        rafraichir_barre(10);
        self.construire();
    }
}

fn arreter_minuteur() {
    executer(&["systemctl", "--user", "stop", &format!("{MINUTEUR_DND}.timer")]);
    let _ = std::fs::remove_file(fin_dnd());
}

fn notification(n: &Value) -> gtk::Box {
    let zone = boite(true, 1);
    zone.set_margin_start(30);
    let haut = boite(false, 8);
    let titre = sans_balises(n["titre"].as_str().unwrap_or_default());
    let titre = etiquette(if titre.is_empty() { "(sans titre)" } else { &titre }, &["notif-titre"]);
    couper(&titre, 34);
    titre.set_hexpand(true);
    haut.append(&titre);
    haut.append(&etiquette(&date_de(n).format("%d/%m  %H:%M").to_string(), &["discret"]));
    zone.append(&haut);
    let texte = sans_balises(n["texte"].as_str().unwrap_or_default());
    if !texte.is_empty() {
        let corps = etiquette(&texte, &["corps"]);
        corps.set_wrap(true);
        corps.set_lines(3);
        corps.set_ellipsize(pango::EllipsizeMode::End);
        corps.set_max_width_chars(52);
        zone.append(&corps);
    }
    zone
}

#[cfg(test)]
mod essais {
    use super::sans_balises;

    #[test]
    fn texte_brut() {
        assert_eq!(sans_balises("<b>gras</b> &amp; co"), "gras & co");
        assert_eq!(sans_balises("  l&apos;essai &#233;t&#xE9; &lt;3 "), "l'essai été <3");
        assert_eq!(sans_balises("&inconnu; reste"), "&inconnu; reste");
    }
}
