//! Capture d'écran façon ShareX : l'écran est photographié à l'instant où l'on appuie sur
//! Impr écran (tout est figé), puis on choisit la zone sur cette photo, au pixel près, avec
//! une loupe ronde qui suit la souris. Ensuite : l'aperçu (Copier, Enregistrer, OCR...).
//!
//!   panneaux selection FICHIER ECRAN   choisir une zone sur la photo FICHIER de l'écran ECRAN
//!   panneaux apercu FICHIER            aperçu direct (capture de l'écran entier)
//!
//! Ce programme dessine avec la carte graphique (rendu "gl"), le seul qui respecte l'échelle
//! fractionnaire de l'écran (1,5) : photo et aperçu sont affichés pixel pour pixel, nets.
//! (Les autres panneaux dessinent avec le processeur, plus léger, sans perte visible pour du texte.)

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{cairo, gdk, gdk_pixbuf, gio, glib};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use crate::App;

const LOUPE: f64 = 120.0; // diamètre de la loupe, en points (environ 2 cm à l'écran)
const PIXELS_LOUPE: f64 = 13.0; // nombre de pixels montrés d'un bord à l'autre de la loupe
const ECART: f64 = 24.0; // distance entre la souris et la loupe
const CYAN: (f64, f64, f64) = (0.0, 0.94, 1.0);

/// Point d'entrée de "panneaux selection" et "panneaux apercu" : un programme à part
/// (pas l'instance unique des panneaux), qui dessine avec la carte graphique.
pub fn principal(arguments: &[String]) -> glib::ExitCode {
    // Avant que GTK ne démarre : rendu par la carte graphique (voir en tête de fichier).
    // SAFETY : aucun autre fil d'exécution n'existe encore à ce moment.
    unsafe { std::env::set_var("GSK_RENDERER", "gl") };
    let mode = arguments.get(1).cloned().unwrap_or_default();
    let fichier = arguments.get(2).cloned().unwrap_or_default();
    let ecran = arguments.get(3).cloned().unwrap_or_default();

    let app = gio::Application::new(None::<&str>, gio::ApplicationFlags::NON_UNIQUE);
    app.connect_startup(|_| {
        crate::demarrer_gtk();
    });
    app.connect_activate(move |app| {
        let etat = crate::nouvel_etat(app);
        if mode == "apercu" {
            apercu(&etat, &fichier);
        } else {
            choisir(&etat, Path::new(&fichier), &ecran);
        }
    });
    app.run_with_args(&[] as &[&str])
}

/// L'aperçu (Copier, Enregistrer, OCR...), dans ce même programme.
fn apercu(app: &App, fichier: &str) {
    app.parametre.replace(Some(fichier.to_owned()));
    app.ouvrir("capture");
}

struct Selection {
    app: App,
    fichier: PathBuf,
    image: gdk_pixbuf::Pixbuf,
    surface: cairo::ImageSurface, // la même photo, pour la loupe
    voile: gtk::DrawingArea,      // assombrit hors de la zone, et l'encadre
    loupe: gtk::DrawingArea,
    debut: Cell<Option<(f64, f64)>>,
    fin: Cell<(f64, f64)>,
    souris: Cell<Option<(f64, f64)>>,
    fenetre: RefCell<Option<gtk::Window>>,
    maintien: RefCell<Option<gio::ApplicationHoldGuard>>,
}

/// Copie de la photo pour cairo (qui range les couleurs dans l'ordre bleu, vert, rouge).
fn surface_cairo(image: &gdk_pixbuf::Pixbuf) -> Option<cairo::ImageSurface> {
    let (largeur, hauteur) = (image.width(), image.height());
    let mut surface = cairo::ImageSurface::create(cairo::Format::Rgb24, largeur, hauteur).ok()?;
    let pas_cairo = surface.stride() as usize;
    let (pas, canaux) = (image.rowstride() as usize, image.n_channels() as usize);
    let octets = image.read_pixel_bytes();
    {
        let mut donnees = surface.data().ok()?;
        for y in 0..hauteur as usize {
            for x in 0..largeur as usize {
                let source = y * pas + x * canaux;
                let cible = y * pas_cairo + x * 4;
                donnees[cible] = octets[source + 2];
                donnees[cible + 1] = octets[source + 1];
                donnees[cible + 2] = octets[source];
            }
        }
    }
    Some(surface)
}

fn texture(image: &gdk_pixbuf::Pixbuf) -> gdk::MemoryTexture {
    let format = if image.has_alpha() { gdk::MemoryFormat::R8g8b8a8 } else { gdk::MemoryFormat::R8g8b8 };
    gdk::MemoryTexture::new(
        image.width(),
        image.height(),
        format,
        &image.read_pixel_bytes(),
        image.rowstride() as usize,
    )
}

fn choisir(app: &App, fichier: &Path, ecran: &str) {
    let Some((image, surface)) =
        gdk_pixbuf::Pixbuf::from_file(fichier).ok().and_then(|i| Some((i.clone(), surface_cairo(&i)?)))
    else {
        crate::outils::notifier("Capture", "Image de l'écran illisible.", true);
        return;
    };

    let fenetre = gtk::Window::new();
    fenetre.init_layer_shell();
    fenetre.set_namespace(Some("selection"));
    fenetre.set_layer(Layer::Overlay);
    for bord in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        fenetre.set_anchor(bord, true);
    }
    fenetre.set_exclusive_zone(-1);
    fenetre.set_keyboard_mode(KeyboardMode::Exclusive);
    // Sur l'écran photographié
    if let Some(affichage) = gdk::Display::default() {
        let moniteurs = affichage.monitors();
        for i in 0..moniteurs.n_items() {
            if let Some(m) = moniteurs.item(i).and_downcast::<gdk::Monitor>()
                && m.connector().as_deref() == Some(ecran)
            {
                fenetre.set_monitor(Some(&m));
            }
        }
    }
    fenetre.set_cursor_from_name(Some("crosshair"));

    // La photo, pixel pour pixel, sous un voile et la loupe
    let photo = gtk::Picture::for_paintable(&texture(&image));
    photo.set_can_shrink(true);
    photo.set_content_fit(gtk::ContentFit::Fill);
    let superposition = gtk::Overlay::new();
    superposition.set_child(Some(&photo));
    let voile = gtk::DrawingArea::new();
    superposition.add_overlay(&voile);
    let loupe = gtk::DrawingArea::new();
    loupe.set_size_request((LOUPE + 4.0) as i32, (LOUPE + 26.0) as i32);
    loupe.set_halign(gtk::Align::Start);
    loupe.set_valign(gtk::Align::Start);
    loupe.set_can_target(false); // ne gêne pas la souris
    loupe.set_visible(false);
    superposition.add_overlay(&loupe);
    fenetre.set_child(Some(&superposition));

    let s = Rc::new(Selection {
        app: Rc::clone(app),
        fichier: fichier.to_path_buf(),
        image,
        surface,
        voile: voile.clone(),
        loupe: loupe.clone(),
        debut: Cell::new(None),
        fin: Cell::new((0.0, 0.0)),
        souris: Cell::new(None),
        fenetre: RefCell::new(Some(fenetre.clone())),
        maintien: RefCell::new(Some(app.app.hold())),
    });

    let x = Rc::clone(&s);
    voile.set_draw_func(move |_, cr, l, h| x.dessiner_voile(cr, l as f64, h as f64));
    let x = Rc::clone(&s);
    loupe.set_draw_func(move |_, cr, _, _| x.dessiner_loupe(cr));

    // La souris : la loupe suit
    let mouvement = gtk::EventControllerMotion::new();
    let x = Rc::clone(&s);
    mouvement.connect_motion(move |_, px, py| x.suivre(px, py));
    voile.add_controller(mouvement);

    // Tracer la zone : appuyer, glisser, relâcher
    let tracer = gtk::GestureDrag::new();
    tracer.set_button(1);
    let x = Rc::clone(&s);
    tracer.connect_drag_begin(move |_, px, py| {
        x.debut.set(Some((px, py)));
        x.fin.set((px, py));
        x.voile.queue_draw();
    });
    let x = Rc::clone(&s);
    tracer.connect_drag_update(move |_, dx, dy| {
        if let Some((px, py)) = x.debut.get() {
            x.fin.set((px + dx, py + dy));
            x.suivre(px + dx, py + dy);
            x.voile.queue_draw();
        }
    });
    let x = Rc::clone(&s);
    tracer.connect_drag_end(move |_, _, _| x.terminer());
    voile.add_controller(tracer);

    // Clic droit ou Échap : annuler
    let annuler = gtk::GestureClick::new();
    annuler.set_button(3);
    let x = Rc::clone(&s);
    annuler.connect_pressed(move |_, _, _, _| x.annuler());
    voile.add_controller(annuler);
    let touches = gtk::EventControllerKey::new();
    let x = Rc::clone(&s);
    touches.connect_key_pressed(move |_, touche, _, _| {
        if touche == gdk::Key::Escape {
            x.annuler();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    fenetre.add_controller(touches);
    fenetre.present();
}

impl Selection {
    /// Pixels de la photo par point d'écran (1,5 sur un écran à l'échelle 1,5).
    fn rapport(&self) -> f64 {
        let largeur = self.voile.width().max(1) as f64;
        self.image.width() as f64 / largeur
    }

    /// Zone choisie, en points d'écran : (x, y, largeur, hauteur).
    fn rectangle(&self) -> Option<(f64, f64, f64, f64)> {
        let (x1, y1) = self.debut.get()?;
        let (x2, y2) = self.fin.get();
        Some((x1.min(x2), y1.min(y2), (x2 - x1).abs(), (y2 - y1).abs()))
    }

    /// Même zone, en pixels de la photo, bornée à l'image.
    fn zone_en_pixels(&self) -> Option<(i32, i32, i32, i32)> {
        let (x, y, l, h) = self.rectangle()?;
        let r = self.rapport();
        let (lmax, hmax) = (self.image.width(), self.image.height());
        let x1 = ((x * r).round() as i32).clamp(0, lmax);
        let y1 = ((y * r).round() as i32).clamp(0, hmax);
        let x2 = (((x + l) * r).round() as i32).clamp(0, lmax);
        let y2 = (((y + h) * r).round() as i32).clamp(0, hmax);
        Some((x1, y1, x2 - x1, y2 - y1))
    }

    fn suivre(&self, px: f64, py: f64) {
        self.souris.set(Some((px, py)));
        let (l, h) = (self.voile.width() as f64, self.voile.height() as f64);
        // La loupe se place en bas à droite de la souris, ou de l'autre côté près des bords
        let (cl, ch) = (LOUPE + 4.0, LOUPE + 26.0);
        let x = if px + ECART + cl > l { px - ECART - cl } else { px + ECART };
        let y = if py + ECART + ch > h { py - ECART - ch } else { py + ECART };
        self.loupe.set_margin_start(x.max(0.0) as i32);
        self.loupe.set_margin_top(y.max(0.0) as i32);
        self.loupe.set_visible(true);
        self.loupe.queue_draw();
    }

    fn dessiner_voile(&self, cr: &cairo::Context, l: f64, h: f64) {
        // Voile sur tout l'écran, sauf sur la zone choisie
        cr.set_fill_rule(cairo::FillRule::EvenOdd);
        cr.rectangle(0.0, 0.0, l, h);
        let zone = self.rectangle();
        if let Some((x, y, zl, zh)) = zone {
            cr.rectangle(x, y, zl, zh);
        }
        cr.set_source_rgba(0.0, 0.0, 0.0, if zone.is_some() { 0.45 } else { 0.25 });
        let _ = cr.fill();
        let (Some((x, y, zl, zh)), Some((_, _, pl, ph))) = (zone, self.zone_en_pixels()) else { return };
        // Cadre cyan et taille en pixels
        cr.set_source_rgb(CYAN.0, CYAN.1, CYAN.2);
        cr.set_line_width(1.5);
        cr.rectangle(x, y, zl, zh);
        let _ = cr.stroke();
        let texte = format!("{pl} × {ph}");
        cr.select_font_face("sans-serif", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        cr.set_font_size(13.0);
        let largeur_texte = cr.text_extents(&texte).map_or(60.0, |e| e.width());
        let ty = if y > 26.0 { y - 8.0 } else { y + zh + 20.0 };
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.75);
        cr.rectangle(x, ty - 15.0, largeur_texte + 12.0, 21.0);
        let _ = cr.fill();
        cr.set_source_rgb(CYAN.0, CYAN.1, CYAN.2);
        cr.move_to(x + 6.0, ty);
        let _ = cr.show_text(&texte);
    }

    /// Loupe ronde : les pixels autour de la souris, agrandis sans flou, le pixel visé encadré.
    fn dessiner_loupe(&self, cr: &cairo::Context) {
        let Some((mx, my)) = self.souris.get() else { return };
        let r = self.rapport();
        let px = ((mx * r).floor()).clamp(0.0, (self.image.width() - 1) as f64);
        let py = ((my * r).floor()).clamp(0.0, (self.image.height() - 1) as f64);
        let (cx, cy, rayon) = (LOUPE / 2.0 + 2.0, LOUPE / 2.0 + 2.0, LOUPE / 2.0);
        let case = LOUPE / PIXELS_LOUPE;

        let _ = cr.save();
        cr.arc(cx, cy, rayon, 0.0, std::f64::consts::TAU);
        cr.clip();
        cr.set_source_rgb(0.0, 0.0, 0.0);
        let _ = cr.paint();
        cr.translate(cx - case * (px + 0.5), cy - case * (py + 0.5));
        cr.scale(case, case);
        if cr.set_source_surface(&self.surface, 0.0, 0.0).is_ok() {
            cr.source().set_filter(cairo::Filter::Nearest); // pixels nets, pas de flou
            let _ = cr.paint();
        }
        let _ = cr.restore();

        // Le pixel visé
        cr.set_source_rgb(CYAN.0, CYAN.1, CYAN.2);
        cr.set_line_width(1.5);
        cr.rectangle(cx - case / 2.0, cy - case / 2.0, case, case);
        let _ = cr.stroke();
        // Contour de la loupe
        cr.set_line_width(2.0);
        cr.arc(cx, cy, rayon, 0.0, std::f64::consts::TAU);
        let _ = cr.stroke();
        // Coordonnées du pixel
        let texte = format!("{px:.0} , {py:.0}");
        cr.select_font_face("sans-serif", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        cr.set_font_size(12.0);
        let largeur_texte = cr.text_extents(&texte).map_or(60.0, |e| e.width());
        let tx = cx - largeur_texte / 2.0;
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.75);
        cr.rectangle(tx - 6.0, LOUPE + 6.0, largeur_texte + 12.0, 18.0);
        let _ = cr.fill();
        cr.set_source_rgb(CYAN.0, CYAN.1, CYAN.2);
        cr.move_to(tx, LOUPE + 19.0);
        let _ = cr.show_text(&texte);
    }

    /// Zone tracée : on découpe la photo, puis l'aperçu s'ouvre.
    fn terminer(self: &Rc<Self>) {
        let Some((x, y, l, h)) = self.zone_en_pixels() else { return };
        if l < 2 || h < 2 {
            // simple clic sans tracer : on recommence
            self.debut.set(None);
            self.voile.queue_draw();
            return;
        }
        let morceau = self.image.new_subpixbuf(x, y, l, h);
        let destination = self.fichier.with_file_name(format!(
            "{}-zone.png",
            self.fichier.file_stem().map_or("capture".into(), |n| n.to_string_lossy())
        ));
        let enregistre = morceau.savev(&destination, "png", &[]).is_ok();
        let _ = std::fs::remove_file(&self.fichier);
        if let Some(fenetre) = self.fenetre.take() {
            fenetre.destroy();
        }
        if enregistre {
            apercu(&self.app, &destination.to_string_lossy());
        } else {
            crate::outils::notifier("Capture", "Impossible de découper l'image.", true);
        }
        self.maintien.take(); // l'aperçu a pris le relais (ou rien : le programme se termine)
    }

    fn annuler(&self) {
        let _ = std::fs::remove_file(&self.fichier);
        if let Some(fenetre) = self.fenetre.take() {
            fenetre.destroy();
        }
        self.maintien.take();
    }
}
