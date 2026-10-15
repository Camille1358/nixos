//! Capture d'écran : aperçu, puis copier / enregistrer / enregistrer sous.
//!
//! L'image vient d'être prise dans un fichier temporaire (en mémoire vive).
//! Copier ne laisse aucune trace : le fichier est effacé juste après.

use std::cell::Cell;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;

use chrono::Local;
use gtk::prelude::*;
use gtk::{gio, glib};

use crate::App;
use crate::outils::{
    boite, bouton_icone, deplacer, en_fond, etiquette, executer_delai, icone, image_ajustee, notifier,
};

/// ~/Images/Captures (le dossier Images suit la langue du système).
fn dossier_captures() -> PathBuf {
    let images = glib::user_special_dir(glib::UserDirectory::Pictures)
        .unwrap_or_else(|| glib::home_dir().join("Images"));
    let dossier = images.join("Captures");
    let _ = std::fs::create_dir_all(&dossier);
    dossier
}

fn nom_de_capture() -> String {
    Local::now().format("Capture_%Y-%m-%d_%H-%M-%S.png").to_string()
}

struct Capture {
    app: App,
    fichier: PathBuf,
    garder: Cell<bool>, // true une fois l'image enregistrée : ne pas l'effacer
}

pub fn creer(app: &App) -> gtk::Box {
    let racine = boite(true, 10);
    let fichier = PathBuf::from(app.parametre.borrow().clone().unwrap_or_default());
    let capture = Rc::new(Capture { app: Rc::clone(app), fichier, garder: Cell::new(false) });

    // Fermer le panneau sans copier ni enregistrer : l'image est effacée
    let c = Rc::clone(&capture);
    app.quand_fermer(move || {
        if !c.garder.get() {
            let _ = std::fs::remove_file(&c.fichier);
        }
    });

    // Aperçu réduit pour tenir à l'écran
    let Some((apercu, largeur, hauteur)) = image_ajustee(&capture.fichier, 760, 460, false) else {
        racine.append(&etiquette("Image de la capture illisible.", &["erreur"]));
        return racine;
    };
    racine.append(&etiquette(&format!("CAPTURE  ·  {largeur} × {hauteur}"), &["titre"]));
    racine.append(&apercu);

    let actions = boite(false, 6);
    actions.set_halign(gtk::Align::Center);
    let c = Rc::clone(&capture);
    actions.append(&bouton_icone(icone::COPIER, "Copier", 0, &[], move || c.copier()));
    let c = Rc::clone(&capture);
    actions.append(&bouton_icone(icone::ENREGISTRER, "Enregistrer", 0, &[], move || {
        c.ranger(&dossier_captures().join(nom_de_capture()));
        c.app.fermer();
    }));
    let c = Rc::clone(&capture);
    actions
        .append(&bouton_icone(icone::DOSSIER, "Enregistrer sous…", 0, &[], move || c.enregistrer_sous()));
    let c = Rc::clone(&capture);
    actions.append(&bouton_icone(icone::TEXTE, "Texte (OCR)", 0, &[], move || c.lire_le_texte()));
    let app = Rc::clone(app);
    actions.append(&bouton_icone(icone::ANNULER, "Annuler", 0, &["danger"], move || app.fermer()));
    racine.append(&actions);
    racine
}

impl Capture {
    fn copier(&self) {
        // wl-copy lit l'image puis reste en arrière-plan pour la fournir au collage
        if let Ok(image) = File::open(&self.fichier) {
            let _ = Command::new("wl-copy")
                .args(["--type", "image/png"])
                .stdin(image)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        self.app.fermer(); // (pas de notification : on vient soi-même de cliquer sur Copier)
    }

    /// OCR : lit le texte de l'image (Tesseract, français et anglais) et le copie dans le
    /// presse-papiers. La lecture prend une à deux secondes : elle se fait sans figer le panneau.
    fn lire_le_texte(self: &Rc<Self>) {
        let chemin = self.fichier.to_string_lossy().into_owned();
        let c = Rc::clone(self);
        en_fond(
            move || executer_delai(&["tesseract", &chemin, "-", "-l", "fra+eng"], 60),
            move |(reussi, texte)| {
                let texte = texte.trim();
                if !reussi || texte.is_empty() {
                    notifier("Texte (OCR)", "Aucun texte trouvé dans l'image.", false);
                    return; // l'aperçu reste ouvert : copier ou enregistrer l'image reste possible
                }
                if let Ok(mut copie) = Command::new("wl-copy").stdin(Stdio::piped()).spawn() {
                    if let Some(mut entree) = copie.stdin.take() {
                        let _ = entree.write_all(texte.as_bytes());
                    }
                    let _ = copie.wait();
                }
                c.app.fermer();
            },
        );
    }

    fn ranger(&self, destination: &Path) {
        if deplacer(&self.fichier, destination).is_ok() {
            self.garder.set(true); // (pas de notification de réussite : seulement les erreurs)
        } else {
            notifier("Capture", "Impossible d'enregistrer l'image à cet endroit.", true);
        }
    }

    fn enregistrer_sous(self: &Rc<Self>) {
        // Le choix du fichier se fait dans une fenêtre normale : on retire d'abord le panneau
        // (qui couvre tout l'écran), sans effacer l'image.
        self.garder.set(true);
        let garde = self.app.app.hold(); // le programme ne doit pas se terminer pendant le choix
        self.app.fermer();
        let choix = gtk::FileDialog::new();
        choix.set_title("Enregistrer la capture");
        choix.set_initial_folder(Some(&gio::File::for_path(dossier_captures())));
        choix.set_initial_name(Some(&nom_de_capture()));
        let c = Rc::clone(self);
        choix.save(None::<&gtk::Window>, None::<&gio::Cancellable>, move |reponse| {
            match reponse.ok().and_then(|f| f.path()) {
                Some(destination) => c.ranger(&destination),
                None => {
                    let _ = std::fs::remove_file(&c.fichier);
                }
            }
            drop(garde);
        });
    }
}
