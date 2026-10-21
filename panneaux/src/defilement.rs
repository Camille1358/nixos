//! Défilement automatique façon Firefox, dans les applications choisies (réglage
//! "defilementAutoApplis", desktop-home.nix) :
//! un clic molette (sans rester appuyé), puis la page défile toute seule vers la souris,
//! sans fin, d'autant plus vite que la souris s'éloigne du point de départ. Un nouveau clic
//! (gauche, droit ou molette) ou Échap arrête. Une petite icône marque le point de départ.
//!
//!   panneaux defilement   démarre (ou arrête, s'il est déjà en route)
//!
//! Vitesse : proportionnelle à l'éloignement de la souris, jusqu'à "defilementVitesseMax" pages
//! par seconde, atteint à "defilementDistanceMax" points (desktop-home.nix). Une "page" = la
//! hauteur de la fenêtre.
//!
//! Lancé par Hyprland à chaque clic molette (desktop-home.nix). Les clics et Échap l'arrêtent
//! en effaçant son fichier témoin (voir la configuration de Hyprland). Le défilement est
//! envoyé par une souris virtuelle (protocole Wayland wlr-virtual-pointer), à l'application
//! sous le curseur ; l'icône est une petite surface Wayland que les clics traversent.

use std::fs::{self, File};
use std::io::Write;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde_json::Value;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_pointer, wl_region, wl_registry, wl_seat, wl_shm, wl_shm_pool, wl_surface,
};
use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};
use wayland_protocols::wp::viewporter::client::{wp_viewport::WpViewport, wp_viewporter::WpViewporter};
use wayland_protocols_wlr::layer_shell::v1::client::{
    zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1},
    zwlr_layer_surface_v1::{self, Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1},
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

use crate::style::THEME;
use crate::systeme::{dossier_session, hyprland};

const ZONE_NEUTRE: f64 = 4.0; // points autour du point de départ où rien ne défile
const IMAGES_PAR_SECONDE: f64 = 60.0;
const ICONE: i32 = 24; // taille de l'icône du point de départ, en points

/// Fichier témoin : il existe tant que le défilement tourne ; l'effacer l'arrête.
pub fn temoin() -> PathBuf {
    dossier_session().join("defilement-auto")
}

/// Position de la souris (demandée à Hyprland 60 fois par seconde, sans lancer de programme).
fn position() -> Option<(f64, f64)> {
    let p = hyprland("cursorpos");
    Some((p["x"].as_f64()?, p["y"].as_f64()?))
}

/// Pixels à défiler par image pour un éloignement donné (en points) : proportionnel à
/// l'éloignement (compté depuis le bord de la zone neutre, pour démarrer en douceur), jusqu'à
/// `max` pages par seconde, atteint à `distance_max` points ; plus loin, ça n'accélère plus.
pub fn vitesse(ecart: f64, distance_max: f64, max: f64, page: f64) -> f64 {
    let loin = ecart.abs() - ZONE_NEUTRE;
    if loin <= 0.0 {
        return 0.0;
    }
    let pages = (loin / distance_max).min(1.0) * max;
    ecart.signum() * pages * page / IMAGES_PAR_SECONDE
}

/// Le défilement démarre-t-il ? Seulement sur un endroit « vide » :
/// - pas dans les `zone_haut` premiers points de la fenêtre (onglets, barres d'outils : le clic
///   molette y ferme un onglet) ;
/// - curseur en flèche normale : pas la main (lien, bouton), ni le I du texte (sauf si
///   `sur_texte`). Forme inconnue (application qui dessine son curseur elle-même, ou Hyprland
///   sans le patch hyprland-forme-curseur.patch) : on démarre.
pub fn peut_demarrer(forme: Option<&str>, dans_fenetre: f64, zone_haut: f64, sur_texte: bool) -> bool {
    if (0.0..zone_haut).contains(&dans_fenetre) {
        return false;
    }
    match forme {
        None | Some("" | "default") => true,
        Some("text" | "vertical-text") => sur_texte,
        Some(_) => false,
    }
}

/// État Wayland : seule la configuration de l'icône (layer surface) nous intéresse.
#[derive(Default)]
struct Etat {
    configuration: Option<u32>,
}

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

impl Dispatch<ZwlrLayerSurfaceV1, ()> for Etat {
    fn event(
        etat: &mut Self,
        surface: &ZwlrLayerSurfaceV1,
        evenement: zwlr_layer_surface_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwlr_layer_surface_v1::Event::Configure { serial, .. } = evenement {
            surface.ack_configure(serial);
            etat.configuration = Some(serial);
        }
    }
}

delegate_noop!(Etat: ignore wl_seat::WlSeat);
delegate_noop!(Etat: ignore wl_shm::WlShm);
delegate_noop!(Etat: ignore wl_buffer::WlBuffer);
delegate_noop!(Etat: ignore wl_surface::WlSurface);
delegate_noop!(Etat: wl_compositor::WlCompositor);
delegate_noop!(Etat: wl_shm_pool::WlShmPool);
delegate_noop!(Etat: wl_region::WlRegion);
delegate_noop!(Etat: WpViewporter);
delegate_noop!(Etat: WpViewport);
delegate_noop!(Etat: ZwlrLayerShellV1);
delegate_noop!(Etat: ZwlrVirtualPointerManagerV1);
delegate_noop!(Etat: ZwlrVirtualPointerV1);

pub fn lancer() {
    let temoin = temoin();
    // Déjà en route : ce clic l'arrête
    if temoin.exists() {
        let _ = fs::remove_file(&temoin);
        return;
    }
    // Seulement dans les applications choisies (réglage "defilementAutoApplis")
    let fenetre = hyprland("activewindow");
    let classe = fenetre["class"].as_str().map(str::to_lowercase).unwrap_or_default();
    if !THEME.defilement_auto_applis.iter().any(|appli| classe.contains(&appli.to_lowercase())) {
        return;
    }
    // Une "page" = la hauteur de la fenêtre active
    let page = fenetre["size"][1].as_f64().filter(|h| *h > 100.0).unwrap_or(900.0);
    let souris = hyprland("cursorpos");
    let (Some(x), Some(y)) = (souris["x"].as_f64(), souris["y"].as_f64()) else { return };
    // La souris doit être DANS la fenêtre : un clic molette sur la barre du haut ne compte pas
    let (Some(fx), Some(fy), Some(fl), Some(fh)) =
        (fenetre["at"][0].as_f64(), fenetre["at"][1].as_f64(), fenetre["size"][0].as_f64(), fenetre["size"][1].as_f64())
    else {
        return;
    };
    if !(fx..fx + fl).contains(&x) || !(fy..fy + fh).contains(&y) {
        return;
    }
    // Sur ce qui se clique (lien, bouton, texte, onglet), le clic molette reste à l'application
    if !peut_demarrer(souris["shape"].as_str(), y - fy, THEME.defilement_zone_haut, THEME.defilement_sur_texte) {
        return;
    }
    if let Err(erreur) = defiler((x, y), page, &temoin) {
        eprintln!("panneaux defilement : {erreur}");
    }
    let _ = fs::remove_file(&temoin);
}

fn defiler(depart: (f64, f64), page: f64, temoin: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let connexion = Connection::connect_to_env()?;
    let (globaux, mut file) = registry_queue_init::<Etat>(&connexion)?;
    let qh = file.handle();
    let mut etat = Etat::default();

    // La souris virtuelle qui envoie le défilement
    let siege: wl_seat::WlSeat = globaux.bind(&qh, 1..=7, ())?;
    let gestionnaire: ZwlrVirtualPointerManagerV1 = globaux.bind(&qh, 1..=2, ())?;
    let souris = gestionnaire.create_virtual_pointer(Some(&siege), &qh, ());

    // L'icône du point de départ (facultative : sans elle, le défilement marche quand même)
    let icone = afficher_icone(&globaux, &qh, depart).ok();
    file.roundtrip(&mut etat)?;
    if let Some(icone) = &icone {
        icone.peindre(etat.configuration.is_some());
    }
    connexion.flush()?;
    fs::write(temoin, std::process::id().to_string())?;

    let debut = Instant::now();
    let image = Duration::from_secs_f64(1.0 / IMAGES_PAR_SECONDE);
    let (distance_max, max) = (THEME.defilement_distance_max, THEME.defilement_vitesse_max);
    // Hyprland multiplie ce défilement par la vitesse de la molette (réglage "defilement") :
    // on la retire, pour que seule la distance compte.
    let facteur = hyprland("getoption input:scroll_factor")["float"].as_f64().filter(|f| *f > 0.0).unwrap_or(1.0);
    // Les fractions de pixel non envoyées sont gardées pour l'image suivante (défilement lent régulier)
    let (mut reste_x, mut reste_y) = (0.0, 0.0);
    let mut precedente = Instant::now();
    while temoin.exists() {
        let Some((x, y)) = position() else { break };
        // Temps réellement écoulé (en images à 60 par seconde) : la vitesse reste la même même
        // si une image arrive en retard (Hyprland occupé pendant que la souris bouge vite)
        let maintenant = Instant::now();
        // (au plus 6 images rattrapées : pas de saut brusque après un long blocage)
        let images = ((maintenant - precedente).as_secs_f64() * IMAGES_PAR_SECONDE).min(6.0);
        precedente = maintenant;
        reste_x += vitesse(x - depart.0, distance_max, max, page) * images / facteur;
        reste_y += vitesse(y - depart.1, distance_max, max, page) * images / facteur;
        let (dx, dy) = (reste_x.trunc(), reste_y.trunc());
        if dx != 0.0 || dy != 0.0 {
            let temps = debut.elapsed().as_millis() as u32;
            // "Source = continue" : la page bouge d'exactement ces pixels. Avec "doigt" (pavé
            // tactile), les applications y voyaient un geste et ajoutaient de l'élan selon la
            // vitesse de la souris. La source est donnée APRÈS chaque mouvement : Hyprland
            // l'efface à chaque mouvement reçu.
            if dy != 0.0 {
                souris.axis(temps, wl_pointer::Axis::VerticalScroll, dy);
                souris.axis_source(wl_pointer::AxisSource::Continuous);
            }
            if dx != 0.0 {
                souris.axis(temps, wl_pointer::Axis::HorizontalScroll, dx);
                souris.axis_source(wl_pointer::AxisSource::Continuous);
            }
            souris.frame();
            reste_x -= dx;
            reste_y -= dy;
        }
        file.dispatch_pending(&mut etat)?;
        connexion.flush()?;
        sleep(image);
    }
    souris.destroy();
    if let Some(icone) = icone {
        icone.surface_couche.destroy();
        icone.surface.destroy();
    }
    connexion.flush()?;
    Ok(())
}

// =============================================================================
// L'icône du point de départ : un rond sombre, cerclé de cyan, avec quatre flèches
// =============================================================================
struct Icone {
    surface: wl_surface::WlSurface,
    surface_couche: ZwlrLayerSurfaceV1,
    tampon: wl_buffer::WlBuffer,
}

impl Icone {
    fn peindre(&self, configuree: bool) {
        if !configuree {
            return;
        }
        self.surface.attach(Some(&self.tampon), 0, 0);
        self.surface.damage_buffer(0, 0, i32::MAX, i32::MAX);
        self.surface.commit();
    }
}

fn afficher_icone(
    globaux: &wayland_client::globals::GlobalList,
    qh: &QueueHandle<Etat>,
    depart: (f64, f64),
) -> Result<Icone, Box<dyn std::error::Error>> {
    let compositeur: wl_compositor::WlCompositor = globaux.bind(qh, 1..=6, ())?;
    let shm: wl_shm::WlShm = globaux.bind(qh, 1..=1, ())?;
    let couches: ZwlrLayerShellV1 = globaux.bind(qh, 1..=4, ())?;
    let viewporter: WpViewporter = globaux.bind(qh, 1..=1, ())?;

    // Écran sous la souris : sa position (pour placer l'icône) et son échelle (pour la netteté)
    let ecran = hyprland("monitors")
        .as_array()
        .and_then(|m| m.iter().find(|m| m["focused"] == true).cloned())
        .unwrap_or(Value::Null);
    let (ex, ey) = (ecran["x"].as_f64().unwrap_or(0.0), ecran["y"].as_f64().unwrap_or(0.0));
    let echelle = ecran["scale"].as_f64().unwrap_or(1.0).max(1.0);

    let surface = compositeur.create_surface(qh, ());
    // Les clics traversent l'icône (zone de saisie vide)
    let vide = compositeur.create_region(qh, ());
    surface.set_input_region(Some(&vide));
    vide.destroy();

    let couche = couches.get_layer_surface(&surface, None, Layer::Overlay, "defilement".into(), qh, ());
    couche.set_size(ICONE as u32, ICONE as u32);
    couche.set_anchor(Anchor::Top | Anchor::Left);
    couche.set_exclusive_zone(-1); // position mesurée depuis le bord de l'écran, barre comprise
    couche.set_keyboard_interactivity(KeyboardInteractivity::None);
    let demi = f64::from(ICONE) / 2.0;
    couche.set_margin((depart.1 - ey - demi).round() as i32, 0, 0, (depart.0 - ex - demi).round() as i32);
    surface.commit();

    // L'image, dessinée aux vrais pixels de l'écran puis ramenée à sa taille en points
    let cote = (f64::from(ICONE) * echelle).round() as i32;
    let pixels = dessiner_icone(cote);
    let chemin = dossier_session().join(format!("defilement-icone-{}", std::process::id()));
    // Ouvert en lecture ET écriture : Hyprland refuse une image partagée en lecture seule
    // ("Couldn't mmap from fd"), et cette erreur coupait tout le défilement.
    let mut fichier = File::options().read(true).write(true).create(true).truncate(true).open(&chemin)?;
    fichier.write_all(&pixels)?;
    let reserve = shm.create_pool(fichier.as_fd(), pixels.len() as i32, qh, ());
    let _ = fs::remove_file(&chemin); // le compositeur garde son accès
    let tampon = reserve.create_buffer(0, cote, cote, cote * 4, wl_shm::Format::Argb8888, qh, ());
    reserve.destroy();
    let vue = viewporter.get_viewport(&surface, qh, ());
    vue.set_destination(ICONE, ICONE);

    Ok(Icone { surface, surface_couche: couche, tampon })
}

/// Pixels de l'icône (ARGB, prémultipliés, ordre de la mémoire : bleu, vert, rouge, alpha),
/// lissés par sur-échantillonnage (4 × 4 points par pixel).
fn dessiner_icone(cote: i32) -> Vec<u8> {
    let c = f64::from(cote);
    let cyan = [0.0, 0.94, 1.0];
    let fond = [0.07, 0.07, 0.12];
    let mut pixels = Vec::with_capacity((cote * cote * 4) as usize);
    for py in 0..cote {
        for px in 0..cote {
            let (mut r, mut g, mut b, mut a) = (0.0, 0.0, 0.0, 0.0);
            for sy in 0..4 {
                for sx in 0..4 {
                    // Coordonnées de 0 à 1 dans l'icône, centre en (0,5 ; 0,5)
                    let x = (f64::from(px) + (f64::from(sx) + 0.5) / 4.0) / c - 0.5;
                    let y = (f64::from(py) + (f64::from(sy) + 0.5) / 4.0) / c - 0.5;
                    let d = x.hypot(y);
                    let (couleur, opacite) = if d > 0.48 {
                        continue; // hors du rond
                    } else if !(0.06..=0.42).contains(&d) || fleche(x, y) {
                        (cyan, 1.0) // cercle, point central et flèches
                    } else {
                        (fond, 0.85)
                    };
                    r += couleur[0] * opacite;
                    g += couleur[1] * opacite;
                    b += couleur[2] * opacite;
                    a += opacite;
                }
            }
            let octet = |v: f64| ((v / 16.0) * 255.0).round().clamp(0.0, 255.0) as u8;
            pixels.extend_from_slice(&[octet(b), octet(g), octet(r), octet(a)]);
        }
    }
    pixels
}

/// Les quatre petites flèches (triangles) vers le haut, le bas, la gauche et la droite.
fn fleche(x: f64, y: f64) -> bool {
    let triangle = |long: f64, large: f64| -> bool {
        // pointe à 0,36 du centre, base à 0,24, demi-largeur 0,10 à la base
        (0.24..=0.36).contains(&long) && large.abs() <= (0.36 - long) / 0.12 * 0.10
    };
    triangle(-y, x) || triangle(y, x) || triangle(-x, y) || triangle(x, y)
}

#[cfg(test)]
mod essais {
    use super::{dessiner_icone, peut_demarrer, vitesse};

    #[test]
    fn vitesse_proportionnelle() {
        let page = 900.0; // pixels
        // Maximum : 3 pages par seconde (900 × 3 / 60 = 45 pixels par image), atteint à 300 points
        assert_eq!(vitesse(0.0, 300.0, 3.0, page), 0.0);
        assert_eq!(vitesse(3.0, 300.0, 3.0, page), 0.0); // zone neutre
        // À mi-distance après la zone neutre : la moitié du maximum
        assert!((vitesse(154.0, 300.0, 3.0, page) - 22.5).abs() < 1e-9);
        assert!(vitesse(-154.0, 300.0, 3.0, page) < 0.0); // souris au-dessus : la page monte
        // Plus loin que la distance maximale : plafonné
        assert!((vitesse(304.0, 300.0, 3.0, page) - 45.0).abs() < 1e-9);
        assert!((vitesse(-900.0, 300.0, 3.0, page) + 45.0).abs() < 1e-9);
    }

    #[test]
    fn demarre_seulement_sur_du_vide() {
        assert!(peut_demarrer(Some("default"), 400.0, 90.0, false));
        assert!(peut_demarrer(None, 400.0, 90.0, false)); // forme inconnue
        assert!(peut_demarrer(Some(""), 400.0, 90.0, false));
        assert!(!peut_demarrer(Some("pointer"), 400.0, 90.0, false)); // lien, bouton
        assert!(!peut_demarrer(Some("text"), 400.0, 90.0, false));
        assert!(peut_demarrer(Some("text"), 400.0, 90.0, true));
        assert!(!peut_demarrer(Some("default"), 30.0, 90.0, false)); // onglets en haut
        assert!(peut_demarrer(Some("default"), 30.0, 0.0, false)); // zone du haut coupée
    }

    #[test]
    fn icone_coins_transparents_centre_cyan() {
        let cote = 54;
        let p = dessiner_icone(cote);
        assert_eq!(p.len(), (cote * cote * 4) as usize);
        assert_eq!(&p[0..4], &[0, 0, 0, 0]); // coin : transparent
        let centre = ((cote / 2 * cote + cote / 2) * 4) as usize;
        assert_eq!(p[centre + 3], 255); // centre opaque
        assert!(p[centre] > 200 && p[centre + 2] < 30); // cyan : beaucoup de bleu, pas de rouge
    }
}
