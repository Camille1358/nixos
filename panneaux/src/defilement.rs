//! Défilement automatique façon Windows, dans toutes les applications :
//! un clic molette, puis la page défile toute seule vers la souris — d'autant plus vite que
//! la souris s'éloigne du point de départ. Un nouveau clic (ou Échap) arrête.
//!
//!   panneaux defilement   démarre (ou arrête, s'il est déjà en route)
//!
//! Lancé par Hyprland à chaque clic molette (desktop-home.nix). Les clics gauche/droit et
//! Échap l'arrêtent en effaçant son fichier témoin (voir la configuration de Hyprland).
//! Le défilement est envoyé par une souris virtuelle (protocole Wayland wlr-virtual-pointer),
//! à l'application sous le curseur. Les applications qui ont déjà le leur (Firefox,
//! Discord : réglage "defilementAutoSauf") sont laissées tranquilles.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde_json::Value;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_pointer, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

use crate::outils::dossier_session;
use crate::style::THEME;

const ZONE_NEUTRE: f64 = 12.0; // points autour du point de départ où rien ne défile
const VITESSE: f64 = 0.12; // pixels défilés par image, par point d'éloignement
const IMAGE: Duration = Duration::from_millis(16); // ~60 fois par seconde

/// Fichier témoin : il existe tant que le défilement tourne ; l'effacer l'arrête.
pub fn temoin() -> PathBuf {
    dossier_session().join("defilement-auto")
}

/// Question à Hyprland par sa prise de communication (sans lancer hyprctl : 60 fois par
/// seconde, ça compte). Exemple : "j/cursorpos".
fn hyprland(question: &str) -> Option<Value> {
    let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let chemin = dossier_session().join("hypr").join(signature).join(".socket.sock");
    let mut prise = UnixStream::connect(chemin).ok()?;
    prise.write_all(question.as_bytes()).ok()?;
    let mut reponse = String::new();
    prise.read_to_string(&mut reponse).ok()?;
    serde_json::from_str(&reponse).ok()
}

fn position() -> Option<(f64, f64)> {
    let p = hyprland("j/cursorpos")?;
    Some((p["x"].as_f64()?, p["y"].as_f64()?))
}

/// Vitesse (pixels par image) pour un éloignement donné, avec la zone neutre au centre.
pub fn vitesse(ecart: f64) -> f64 {
    let au_dela = ecart.abs() - ZONE_NEUTRE;
    if au_dela <= 0.0 { 0.0 } else { ecart.signum() * au_dela * VITESSE }
}

struct Etat;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Etat {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_seat::WlSeat, ()> for Etat {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrVirtualPointerManagerV1, ()> for Etat {
    fn event(
        _: &mut Self,
        _: &ZwlrVirtualPointerManagerV1,
        _: <ZwlrVirtualPointerManagerV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrVirtualPointerV1, ()> for Etat {
    fn event(
        _: &mut Self,
        _: &ZwlrVirtualPointerV1,
        _: <ZwlrVirtualPointerV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

pub fn lancer() {
    let temoin = temoin();
    // Déjà en route : ce clic l'arrête
    if temoin.exists() {
        let _ = fs::remove_file(&temoin);
        return;
    }
    // Applications qui ont leur propre défilement automatique : on ne s'en mêle pas
    let classe = hyprland("j/activewindow")
        .and_then(|f| f["class"].as_str().map(str::to_lowercase))
        .unwrap_or_default();
    if THEME.defilement_auto_sauf.iter().any(|sauf| classe.contains(&sauf.to_lowercase())) {
        return;
    }
    let Some(depart) = position() else { return };
    if let Err(erreur) = defiler(depart, &temoin) {
        eprintln!("panneaux defilement : {erreur}");
    }
    let _ = fs::remove_file(&temoin);
}

fn defiler(depart: (f64, f64), temoin: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let connexion = Connection::connect_to_env()?;
    let (globaux, mut file) = registry_queue_init::<Etat>(&connexion)?;
    let qh = file.handle();
    let siege: wl_seat::WlSeat = globaux.bind(&qh, 1..=7, ())?;
    let gestionnaire: ZwlrVirtualPointerManagerV1 = globaux.bind(&qh, 1..=2, ())?;
    let souris = gestionnaire.create_virtual_pointer(Some(&siege), &qh, ());
    file.roundtrip(&mut Etat)?;
    fs::write(temoin, std::process::id().to_string())?;

    let debut = Instant::now();
    // Les fractions de pixel non envoyées sont gardées pour l'image suivante (défilement lent régulier)
    let (mut reste_x, mut reste_y) = (0.0, 0.0);
    while temoin.exists() {
        let Some((x, y)) = position() else { break };
        reste_x += vitesse(x - depart.0);
        reste_y += vitesse(y - depart.1);
        let (dx, dy) = (reste_x.trunc(), reste_y.trunc());
        if dx != 0.0 || dy != 0.0 {
            let temps = debut.elapsed().as_millis() as u32;
            souris.axis_source(wl_pointer::AxisSource::Finger);
            if dy != 0.0 {
                souris.axis(temps, wl_pointer::Axis::VerticalScroll, dy);
            }
            if dx != 0.0 {
                souris.axis(temps, wl_pointer::Axis::HorizontalScroll, dx);
            }
            souris.frame();
            connexion.flush()?;
            reste_x -= dx;
            reste_y -= dy;
        }
        sleep(IMAGE);
    }
    // Fin du geste : les applications ne continuent pas sur leur élan
    let temps = debut.elapsed().as_millis() as u32;
    souris.axis_source(wl_pointer::AxisSource::Finger);
    souris.axis_stop(temps, wl_pointer::Axis::VerticalScroll);
    souris.axis_stop(temps, wl_pointer::Axis::HorizontalScroll);
    souris.frame();
    souris.destroy();
    connexion.flush()?;
    Ok(())
}

#[cfg(test)]
mod essais {
    use super::vitesse;

    #[test]
    fn zone_neutre_et_sens() {
        assert_eq!(vitesse(0.0), 0.0);
        assert_eq!(vitesse(10.0), 0.0); // dans la zone neutre
        assert!(vitesse(100.0) > 0.0); // souris en dessous : la page descend
        assert!(vitesse(-100.0) < 0.0); // souris au-dessus : la page monte
        assert!(vitesse(200.0) > vitesse(100.0)); // plus loin = plus vite
    }
}
