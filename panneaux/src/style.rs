//! Couleurs, police et réglages reçus de Nix, et la feuille de style des panneaux.
//!
//! desktop-home.nix écrit un petit fichier JSON (désigné par la variable PANNEAUX_THEME) :
//! rien n'est à régler ici.

use std::fmt::Write as _;
use std::sync::LazyLock;

use serde_json::Value;

pub struct Theme {
    /// Nom de couleur ("cyan", "bg"...) -> code hexadécimal sans "#"
    pub couleurs: Vec<(String, String)>,
    pub police: String,
    pub hauteur_barre: i32,
    pub ordi_en_veille_apres: i64,
    /// Nombre de notifications au survol de la cloche, et cloche animée ou non
    pub notifs_survol: usize,
    pub cloche_animee: bool,
    /// Pas du volume (en %) pour les touches multimédia
    pub pas_volume: u64,
    /// Alerte si le point le plus chaud de la carte graphique atteint ce seuil (°C) ; None = jamais
    pub alerte_chaleur: Option<i64>,
}

impl Theme {
    /// Code hexadécimal (sans "#") d'une couleur du thème
    pub fn couleur(&self, nom: &str) -> &str {
        self.couleurs.iter().find(|(n, _)| n == nom).map_or("ffffff", |(_, c)| c.as_str())
    }
}

pub static THEME: LazyLock<Theme> = LazyLock::new(|| {
    let chemin = std::env::var("PANNEAUX_THEME").unwrap_or_default();
    let json: Value = std::fs::read_to_string(&chemin)
        .ok()
        .and_then(|texte| serde_json::from_str(&texte).ok())
        .unwrap_or(Value::Null);
    let couleurs = json["couleurs"]
        .as_object()
        .map(|c| c.iter().filter_map(|(nom, code)| Some((nom.clone(), code.as_str()?.to_owned()))).collect())
        .unwrap_or_default();
    Theme {
        couleurs,
        police: json["police"].as_str().unwrap_or("monospace").to_owned(),
        hauteur_barre: json["hauteurBarre"].as_i64().unwrap_or(44) as i32,
        ordi_en_veille_apres: json["ordiEnVeilleApres"].as_i64().unwrap_or(30),
        notifs_survol: json["notifsSurvol"].as_u64().unwrap_or(10) as usize,
        cloche_animee: json["clocheAnimee"].as_bool().unwrap_or(false),
        pas_volume: json["pasVolume"].as_u64().unwrap_or(5).max(1),
        alerte_chaleur: json["alerteChaleur"].as_i64(),
    }
});

/// La feuille de style : chaque couleur du thème devient "@nom" (ex. @cyan).
pub fn feuille() -> String {
    let mut css = String::with_capacity(CSS.len() + 1024);
    for (nom, code) in &THEME.couleurs {
        let _ = writeln!(css, "@define-color {nom} #{code};");
    }
    let _ = writeln!(css, "* {{ font-family: \"{}\"; font-size: 14px; }}", THEME.police);
    css.push_str(CSS);
    css
}

const CSS: &str = r"
window { background: transparent; }
.attrape-clic { background: rgba(0, 0, 0, 0.004); }
#panneau {
    background: alpha(@bg, 0.94);
    border: 2px solid @cyan;
    border-radius: 12px;
    color: @text;
}
button {
    background: transparent; background-image: none; border: none; box-shadow: none;
    outline: none; text-shadow: none; color: @text; border-radius: 8px; padding: 7px 10px;
    min-height: 0; min-width: 0;
}
button:hover, button:focus { background: @surface2; color: @cyan; }
button.danger:hover, button.danger:focus { color: @red; }
button.choisi { color: @cyan; }
button.titre-cal { font-weight: bold; color: @cyan; padding: 7px 6px; }
button.jour { padding: 6px 0; min-width: 34px; border-radius: 8px; }
.semaine { color: @violet; padding: 6px 0; min-width: 34px; }
button.hors { color: @muted; }
button.jour:hover, button.jour:focus { background: @surface2; color: @cyan; }
button.auj, button.auj:hover, button.auj:focus {
    background: @cyan; color: @bg; font-weight: bold;
}
button.auj:hover { background: @text; }
.titre { color: @violet; font-size: 12px; }
.discret { color: @muted; font-size: 12px; }
.erreur { color: @red; font-size: 12px; }
.icone { min-width: 22px; }
entry {
    background: @surface; color: @text; border: 1px solid @surface2; outline: none;
    border-radius: 8px; padding: 6px 10px; caret-color: @cyan; box-shadow: none;
}
entry:focus-within { border-color: @cyan; }
scale { padding: 4px 7px; } /* 7 px : la pastille (14 px) reste dans le rail, même en butée */
scale trough { background: @surface2; min-height: 6px; border-radius: 3px; border: none; outline: none; }
scale highlight { background: @cyan; border-radius: 3px; border: none; }
scale slider {
    background: @text; min-width: 14px; min-height: 14px; border-radius: 7px;
    border: none; box-shadow: none; margin: -5px; outline: none;
}
separator { background: @surface2; min-height: 1px; margin: 4px 0; }

/* Réseau : grandes tuiles Wi-Fi / Mode avion / Bluetooth, comme KDE Plasma */
button.tuile {
    background: @surface; border: 1px solid @surface2;
    border-radius: 10px; padding: 10px 4px;
}
button.tuile:hover, button.tuile:focus { background: @surface2; }
button.tuile.allumee {
    background: alpha(@cyan, 0.18); border-color: @cyan; color: @cyan;
}
button.tuile:disabled { opacity: 0.4; }
.grosse-icone { font-size: 20px; }
button.petit { padding: 3px 8px; font-size: 12px; color: @muted; }
button.petit:hover { color: @red; }

/* Notifications */
.appli { font-weight: bold; color: @cyan; }
.notif-titre { font-weight: bold; }
.corps { color: @muted; font-size: 13px; }

/* Alt+Tab : une carte par fenêtre */
.carte { background: alpha(@surface, 0.9); border: 2px solid transparent; border-radius: 12px; }
.carte.choisie { border-color: @cyan; background: alpha(@cyan, 0.14); }
.miniature { background: @bg; border-radius: 8px; }
";
