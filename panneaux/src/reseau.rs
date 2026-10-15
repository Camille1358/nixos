//! Réseau et Bluetooth (clic sur le module réseau de la barre), comme KDE Plasma :
//! tuiles Wi-Fi / Mode avion / Bluetooth, connexions filaires, réseaux Wi-Fi,
//! appareils Bluetooth (associés, et recherche des nouveaux).

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use regex::Regex;

use crate::App;
use crate::outils::{
    boite, bouton, bouton_icone, dossier_session, en_fond, etiquette, etiquette_centree, executer,
    executer_delai, icone, lancer, notifier, separateur, vider,
};

fn nmcli(arguments: &[&str], delai: u64) -> (bool, String) {
    let mut commande = vec!["nmcli"];
    commande.extend_from_slice(arguments);
    executer_delai(&commande, delai)
}

/// Découpe une ligne de "nmcli -t" (les ":" contenus dans les valeurs sont écrits "\:").
pub fn champs(ligne: &str) -> Vec<String> {
    let mut resultat = vec![String::new()];
    let mut lettres = ligne.chars().peekable();
    while let Some(c) = lettres.next() {
        match c {
            '\\' if lettres.peek() == Some(&':') => {
                resultat.last_mut().unwrap().push(':');
                lettres.next();
            }
            ':' => resultat.push(String::new()),
            _ => resultat.last_mut().unwrap().push(c),
        }
    }
    resultat
}

fn lignes_nmcli(arguments: &[&str]) -> Vec<Vec<String>> {
    nmcli(arguments, 5).1.lines().map(champs).collect()
}

/// Pour chaque type de radio ("wlan", "bluetooth"...) : true si elle est coupée.
fn radios_coupees() -> BTreeMap<String, bool> {
    let (_, texte) = executer(&["rfkill", "--noheadings", "--output", "TYPE,SOFT"]);
    let mut etats = BTreeMap::new();
    for ligne in texte.lines() {
        if let [radio, etat] = ligne.split_whitespace().collect::<Vec<_>>()[..] {
            let coupee = etats.get(radio).copied().unwrap_or(true) && etat == "blocked";
            etats.insert(radio.to_owned(), coupee);
        }
    }
    etats
}

struct Wifi {
    nom: String,
    signal: i32,
    actif: bool,
    securise: bool,
}

/// Réseaux Wi-Fi visibles, un par nom : le réseau connecté d'abord, puis le plus fort.
fn reseaux_wifi() -> Vec<Wifi> {
    let mut reseaux: Vec<Wifi> = Vec::new();
    for c in
        lignes_nmcli(&["-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"])
    {
        if c.len() < 4 || c[1].is_empty() {
            continue; // réseau caché (sans nom)
        }
        let nouveau = Wifi {
            nom: c[1].clone(),
            signal: c[2].parse().unwrap_or(0),
            actif: c[0] == "*",
            securise: !matches!(c[3].as_str(), "" | "--"),
        };
        match reseaux.iter_mut().find(|r| r.nom == nouveau.nom) {
            None => reseaux.push(nouveau),
            Some(ancien) => {
                if nouveau.actif || (nouveau.signal > ancien.signal && !ancien.actif) {
                    *ancien = nouveau;
                }
            }
        }
    }
    reseaux.sort_by_key(|r| (!r.actif, -r.signal));
    reseaux
}

/// [(adresse, nom)] des appareils Bluetooth ("Paired" = associés, "Connected" = connectés).
fn appareils_bluetooth(filtre: Option<&str>) -> Vec<(String, String)> {
    let mut commande = vec!["bluetoothctl", "devices"];
    commande.extend(filtre);
    let (_, texte) = executer(&commande);
    let appareil = Regex::new(r"(?m)^Device ([0-9A-F:]{17}) (.+)$").unwrap();
    let sans_nom = Regex::new(r"^([0-9A-F]{2}-){5}[0-9A-F]{2}$").unwrap();
    appareil
        .captures_iter(&texte)
        .filter(|m| !sans_nom.is_match(&m[2]))
        .map(|m| (m[1].to_owned(), m[2].to_owned()))
        .collect()
}

fn icone_bluetooth(adresse: &str) -> &'static str {
    let (_, texte) = executer(&["bluetoothctl", "info", adresse]);
    let genre = Regex::new(r"Icon: (\S+)").unwrap();
    match genre.captures(&texte).as_ref().map(|m| m.get(1).unwrap().as_str()) {
        Some("audio-headset" | "audio-headphones") => icone::CASQUE,
        Some("audio-card") => icone::SON,
        Some("input-keyboard") => icone::CLAVIER,
        Some("input-mouse") => icone::SOURIS,
        Some("phone") => icone::TELEPHONE,
        Some("input-gaming") => icone::MANETTE,
        _ => icone::BLUETOOTH,
    }
}

/// État des radios avant le mode avion, pour le retrouver en le quittant
fn avant_avion() -> std::path::PathBuf {
    dossier_session().join("avant-mode-avion.json")
}

type Resultat = (bool, String);

struct Reseau {
    app: App,
    numero: u64,
    racine: gtk::Box,
    mot_de_passe_pour: RefCell<Option<String>>, // réseau Wi-Fi dont on tape le mot de passe
    en_cours: RefCell<HashSet<String>>,         // actions lancées et pas encore terminées
    recherche: Cell<bool>,                      // recherche d'appareils Bluetooth en cours
    trouves: RefCell<Vec<(String, String)>>,    // appareils Bluetooth trouvés par la recherche
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 4);
    racine.set_size_request(410, -1);
    let r = Rc::new(Reseau {
        app: Rc::clone(app),
        numero: app.numero(),
        racine: racine.clone(),
        mot_de_passe_pour: RefCell::new(None),
        en_cours: RefCell::new(HashSet::new()),
        recherche: Cell::new(false),
        trouves: RefCell::new(Vec::new()),
    });
    r.construire();
    let r2 = Rc::clone(&r);
    en_fond(|| nmcli(&["device", "wifi", "rescan"], 10), move |_| r2.rafraichir());
    // Mise à jour toutes les 5 secondes
    let r2 = Rc::clone(&r);
    let minuteur = glib::timeout_add_local(Duration::from_secs(5), move || {
        r2.rafraichir();
        glib::ControlFlow::Continue
    });
    let minuteur = RefCell::new(Some(minuteur));
    app.quand_fermer(move || {
        if let Some(m) = minuteur.take() {
            m.remove();
        }
    });
    racine
}

impl Reseau {
    fn affiche(&self) -> bool {
        self.app.affiche(self.numero)
    }

    fn rafraichir(self: &Rc<Self>) {
        // pas pendant la saisie d'un mot de passe (elle serait effacée)
        if self.affiche() && self.mot_de_passe_pour.borrow().is_none() && self.en_cours.borrow().is_empty() {
            self.construire();
        }
    }

    /// Lance une action en arrière-plan ; le panneau affiche "…" en attendant.
    fn action(
        self: &Rc<Self>,
        cle: String,
        travail: impl FnOnce() -> Resultat + Send + 'static,
        echec: &str,
    ) {
        self.en_cours.borrow_mut().insert(cle.clone());
        self.construire();
        let (r, echec) = (Rc::clone(self), echec.to_owned());
        en_fond(travail, move |(reussi, _)| {
            r.en_cours.borrow_mut().remove(&cle);
            if !reussi {
                notifier("Réseau", &echec, false);
            }
            if r.affiche() {
                r.construire();
            }
        });
    }

    // --- Construction ---------------------------------------------------------
    fn construire(self: &Rc<Self>) {
        vider(&self.racine);
        let radios = radios_coupees();
        let avion = !radios.is_empty() && radios.values().all(|&coupee| coupee);
        let cartes = lignes_nmcli(&["-t", "-f", "DEVICE,TYPE,STATE", "device"]);
        let carte_wifi = cartes.iter().find(|c| c.len() > 1 && c[1] == "wifi").map(|c| c[0].clone());
        let wifi_allume = nmcli(&["radio", "wifi"], 5).1.trim() == "enabled"
            && !radios.get("wlan").copied().unwrap_or(false);
        let bt_present = radios.contains_key("bluetooth");
        let bt_allume = bt_present
            && !radios["bluetooth"]
            && executer(&["bluetoothctl", "show"]).1.contains("Powered: yes");

        let tuiles = boite(false, 6);
        tuiles.set_homogeneous(true);
        if carte_wifi.is_some() {
            let r = Rc::clone(self);
            tuiles.append(&tuile("Wi-Fi", icone::WIFI, wifi_allume, !avion, move |allumer| {
                r.basculer_wifi(allumer)
            }));
        }
        let r = Rc::clone(self);
        tuiles.append(&tuile("Mode avion", icone::AVION, avion, true, move |activer| {
            r.basculer_avion(activer)
        }));
        if bt_present {
            let r = Rc::clone(self);
            tuiles.append(&tuile("Bluetooth", icone::BLUETOOTH, bt_allume, !avion, move |allumer| {
                r.basculer_bluetooth(allumer)
            }));
        }
        self.racine.append(&tuiles);

        self.section_filaire(&cartes);
        if let Some(carte) = carte_wifi.filter(|_| wifi_allume) {
            self.section_wifi(&carte);
        }
        if bt_allume {
            self.section_bluetooth();
        }
        self.racine.append(&separateur());
        let r = Rc::clone(self);
        self.racine.append(&bouton_icone(
            icone::REGLAGES,
            "Paramètres réseau avancés",
            0,
            &[],
            move || {
                r.app.fermer();
                lancer(&["nm-connection-editor"]);
            },
        ));
    }

    /// Une connexion : clic = s'y connecter ; "Déconnecter" à droite si elle est active.
    #[allow(clippy::too_many_arguments)]
    fn ligne(
        &self,
        texte: &str,
        icone: &str,
        active: bool,
        connecter: impl Fn() + 'static,
        deconnecter: impl Fn() + 'static,
        detail: &str,
        attente: bool,
    ) -> gtk::Box {
        let rangee = boite(false, 4);
        let texte = if attente { format!("{texte}  · connexion…") } else { texte.to_owned() };
        let classes: &[&str] = if active { &["choisi"] } else { &[] };
        let actif = !(active || attente);
        let principal = bouton_icone(icone, &texte, 26, classes, move || {
            if actif {
                connecter();
            }
        });
        principal.set_hexpand(true);
        rangee.append(&principal);
        if !detail.is_empty() {
            rangee.append(&etiquette(detail, &["discret"]));
        }
        if active {
            rangee.append(&bouton("Déconnecter", &["petit"], deconnecter));
        }
        rangee
    }

    fn section_filaire(self: &Rc<Self>, cartes: &[Vec<String>]) {
        if !cartes.iter().any(|c| c.len() > 1 && c[1] == "ethernet") {
            return;
        }
        self.racine.append(&etiquette("FILAIRE", &["titre"]));
        let profils: Vec<Vec<String>> =
            lignes_nmcli(&["-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show"])
                .into_iter()
                .filter(|c| c.len() > 3 && c[2] == "802-3-ethernet")
                .collect();
        if profils.is_empty() {
            self.racine.append(&etiquette("Aucune connexion filaire enregistrée.", &["discret"]));
        }
        for p in profils {
            let (nom, uuid, carte) = (p[0].clone(), p[1].clone(), p[3].clone());
            let attente = self.en_cours.borrow().contains(&format!("eth:{uuid}"));
            let (r1, r2, u, c) = (Rc::clone(self), Rc::clone(self), uuid.clone(), carte.clone());
            self.racine.append(&self.ligne(
                &nom,
                icone::ETHERNET,
                !carte.is_empty(),
                move || {
                    let u = u.clone();
                    r1.action(
                        format!("eth:{u}"),
                        move || nmcli(&["connection", "up", "uuid", &u], 30),
                        ECHEC,
                    );
                },
                move || {
                    let c = c.clone();
                    r2.action(format!("eth:{c}"), move || nmcli(&["device", "disconnect", &c], 15), ECHEC);
                },
                "",
                attente,
            ));
        }
    }

    fn section_wifi(self: &Rc<Self>, carte: &str) {
        self.racine.append(&separateur());
        self.racine.append(&etiquette("WI-FI", &["titre"]));
        let enregistres: Rc<HashSet<String>> = Rc::new(
            lignes_nmcli(&["-t", "-f", "NAME,TYPE", "connection", "show"])
                .into_iter()
                .filter(|c| c.len() > 1 && c[1] == "802-11-wireless")
                .map(|c| c[0].clone())
                .collect(),
        );
        let reseaux = reseaux_wifi();
        if reseaux.is_empty() {
            self.racine.append(&etiquette("Recherche des réseaux…", &["discret"]));
        }
        for reseau in reseaux.into_iter().take(8) {
            let nom = reseau.nom.clone();
            let mut detail = format!("{} %", reseau.signal);
            if reseau.securise {
                detail.push_str(&format!("  {}", icone::CADENAS));
            }
            let attente = self.en_cours.borrow().contains(&format!("wifi:{nom}"));
            let (r1, r2, n, e, c) =
                (Rc::clone(self), Rc::clone(self), nom.clone(), Rc::clone(&enregistres), carte.to_owned());
            let securise = reseau.securise;
            self.racine.append(&self.ligne(
                &nom,
                icone::WIFI,
                reseau.actif,
                move || r1.connecter_wifi(&n, securise, &e),
                move || {
                    let c = c.clone();
                    r2.action("wifi".to_owned(), move || nmcli(&["device", "disconnect", &c], 15), ECHEC);
                },
                &detail,
                attente,
            ));
            if self.mot_de_passe_pour.borrow().as_deref() == Some(nom.as_str()) {
                let saisie = gtk::Entry::new();
                saisie.set_visibility(false);
                saisie.set_placeholder_text(Some(&format!("Mot de passe de « {nom} », puis Entrée")));
                saisie.set_margin_start(34);
                let r = Rc::clone(self);
                saisie.connect_activate(move |champ| r.connecter_avec_mot_de_passe(&nom, &champ.text()));
                self.racine.append(&saisie);
                let s = saisie.clone();
                glib::idle_add_local_once(move || {
                    s.grab_focus();
                });
            }
        }
    }

    fn section_bluetooth(self: &Rc<Self>) {
        self.racine.append(&separateur());
        self.racine.append(&etiquette("BLUETOOTH", &["titre"]));
        let connectes: HashSet<String> =
            appareils_bluetooth(Some("Connected")).into_iter().map(|(a, _)| a).collect();
        let associes = appareils_bluetooth(Some("Paired"));
        if associes.is_empty() {
            self.racine.append(&etiquette("Aucun appareil associé.", &["discret"]));
        }
        for (adresse, nom) in &associes {
            let attente = self.en_cours.borrow().contains(&format!("bt:{adresse}"));
            let (r1, r2, a1, a2) = (Rc::clone(self), Rc::clone(self), adresse.clone(), adresse.clone());
            self.racine.append(&self.ligne(
                nom,
                icone_bluetooth(adresse),
                connectes.contains(adresse),
                move || {
                    let a = a1.clone();
                    r1.action(
                        format!("bt:{a}"),
                        move || executer_delai(&["bluetoothctl", "connect", &a], 20),
                        "Impossible de se connecter : l'appareil est-il allumé et à portée ?",
                    );
                },
                move || {
                    let a = a2.clone();
                    r2.action(
                        format!("bt:{a}"),
                        move || executer_delai(&["bluetoothctl", "disconnect", &a], 10),
                        ECHEC,
                    );
                },
                "",
                attente,
            ));
        }
        let deja: HashSet<&String> = associes.iter().map(|(a, _)| a).collect();
        let nouveaux: Vec<(String, String)> =
            self.trouves.borrow().iter().filter(|(a, _)| !deja.contains(a)).cloned().collect();
        if !nouveaux.is_empty() {
            self.racine.append(&etiquette("À PROXIMITÉ — clic pour associer", &["titre"]));
        }
        for (adresse, nom) in nouveaux {
            let mut texte = nom;
            if self.en_cours.borrow().contains(&format!("bt:{adresse}")) {
                texte.push_str("  · association…");
            }
            let r = Rc::clone(self);
            self.racine
                .append(&bouton_icone(icone::BLUETOOTH, &texte, 34, &[], move || r.associer(&adresse)));
        }
        let texte =
            if self.recherche.get() { "Recherche en cours… (10 s)" } else { "Rechercher des appareils" };
        let r = Rc::clone(self);
        self.racine.append(&bouton_icone(icone::RECHERCHE, texte, 0, &[], move || r.rechercher()));
    }

    // --- Actions --------------------------------------------------------------
    fn basculer_wifi(self: &Rc<Self>, allumer: bool) {
        self.action(
            "radio-wifi".to_owned(),
            move || {
                if allumer {
                    executer(&["rfkill", "unblock", "wlan"]);
                }
                nmcli(&["radio", "wifi", if allumer { "on" } else { "off" }], 5)
            },
            ECHEC,
        );
    }

    fn basculer_avion(self: &Rc<Self>, activer: bool) {
        self.action(
            "avion".to_owned(),
            move || {
                if activer {
                    // pour tout remettre comme avant en quittant le mode avion
                    let avant = serde_json::to_string(&radios_coupees()).unwrap_or_default();
                    let _ = std::fs::write(avant_avion(), avant);
                    return executer(&["rfkill", "block", "all"]);
                }
                let avant: BTreeMap<String, bool> = std::fs::read_to_string(avant_avion())
                    .ok()
                    .and_then(|t| serde_json::from_str(&t).ok())
                    .unwrap_or_default();
                let etait_coupee = |radio: &str| avant.get(radio).copied().unwrap_or(false);
                for radio in ["wlan", "bluetooth", "wwan"] {
                    if !etait_coupee(radio) {
                        executer(&["rfkill", "unblock", radio]);
                    }
                }
                if !etait_coupee("wlan") {
                    nmcli(&["radio", "wifi", "on"], 5);
                }
                (true, String::new())
            },
            ECHEC,
        );
    }

    fn basculer_bluetooth(self: &Rc<Self>, allumer: bool) {
        self.action(
            "radio-bt".to_owned(),
            move || {
                if !allumer {
                    return executer(&["rfkill", "block", "bluetooth"]);
                }
                executer(&["rfkill", "unblock", "bluetooth"]);
                std::thread::sleep(Duration::from_millis(1500)); // le temps que l'adaptateur réapparaisse
                executer(&["bluetoothctl", "power", "on"])
            },
            ECHEC,
        );
    }

    fn connecter_wifi(self: &Rc<Self>, nom: &str, securise: bool, enregistres: &HashSet<String>) {
        let n = nom.to_owned();
        if enregistres.contains(nom) {
            self.action(format!("wifi:{nom}"), move || nmcli(&["connection", "up", "id", &n], 40), ECHEC);
        } else if !securise {
            self.action(format!("wifi:{nom}"), move || nmcli(&["device", "wifi", "connect", &n], 40), ECHEC);
        } else {
            // réseau protégé jamais utilisé : demander le mot de passe
            self.mot_de_passe_pour.replace(Some(n));
            self.construire();
        }
    }

    fn connecter_avec_mot_de_passe(self: &Rc<Self>, nom: &str, mot_de_passe: &str) {
        self.mot_de_passe_pour.replace(None);
        let (n, m) = (nom.to_owned(), mot_de_passe.to_owned());
        self.action(
            format!("wifi:{nom}"),
            move || nmcli(&["device", "wifi", "connect", &n, "password", &m], 40),
            "Connexion impossible : mot de passe incorrect, ou réseau hors de portée.",
        );
    }

    fn rechercher(self: &Rc<Self>) {
        if self.recherche.get() {
            return;
        }
        self.recherche.set(true);
        self.construire();
        let r = Rc::clone(self);
        en_fond(
            || {
                executer_delai(&["bluetoothctl", "--timeout", "10", "scan", "on"], 15);
                appareils_bluetooth(None)
            },
            move |trouves| {
                r.recherche.set(false);
                r.trouves.replace(trouves);
                if r.affiche() {
                    r.construire();
                }
            },
        );
    }

    fn associer(self: &Rc<Self>, adresse: &str) {
        let a = adresse.to_owned();
        self.action(
            format!("bt:{adresse}"),
            move || {
                executer_delai(&["bluetoothctl", "--agent", "NoInputNoOutput", "pair", &a], 30);
                executer(&["bluetoothctl", "trust", &a]);
                executer_delai(&["bluetoothctl", "connect", &a], 20)
            },
            "Association impossible : l'appareil est-il en mode appairage ?",
        );
    }
}

const ECHEC: &str = "L'opération n'a pas abouti.";

/// Grande tuile (Wi-Fi, Mode avion, Bluetooth) : clic = basculer.
fn tuile(
    texte: &str,
    icone: &str,
    allumee: bool,
    active: bool,
    action: impl Fn(bool) + 'static,
) -> gtk::Button {
    let b = gtk::Button::new();
    b.set_has_frame(false);
    let contenu = boite(true, 4);
    contenu.append(&etiquette_centree(icone, &["grosse-icone"]));
    contenu.append(&etiquette_centree(texte, &[]));
    b.set_child(Some(&contenu));
    b.add_css_class("tuile");
    if allumee {
        b.add_css_class("allumee");
    }
    b.set_sensitive(active);
    b.connect_clicked(move |_| action(!allumee));
    b
}

#[cfg(test)]
mod essais {
    use super::champs;

    #[test]
    fn decoupage_nmcli() {
        assert_eq!(champs("*:Ma Box:80:WPA2"), ["*", "Ma Box", "80", "WPA2"]);
        assert_eq!(champs(r"Wifi\:5G:AA\:BB::x"), ["Wifi:5G", "AA:BB", "", "x"]);
        assert_eq!(champs(""), [""]);
    }
}
