//! "Attrape-clic" du lanceur d'applications (Rofi).
//!
//! Rofi ne se ferme pas quand on clique ailleurs. On place donc, juste sous lui, une surface
//! transparente qui couvre l'écran (barre comprise) : un clic dessus ferme Rofi. Elle ne prend
//! pas le clavier, qui reste à Rofi. Lancée et arrêtée par le script "lanceur" (desktop-home.nix).

use gtk::glib;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use crate::outils;

pub fn lancer() -> glib::ExitCode {
    // Pas d'instance unique : indépendant des panneaux, plusieurs peuvent coexister
    if !crate::demarrer_gtk() {
        return glib::ExitCode::FAILURE;
    }
    let boucle = glib::MainLoop::new(None, false);
    {
        let fenetre = gtk::Window::new();
        fenetre.init_layer_shell();
        fenetre.set_namespace(Some("attrape-clic"));
        fenetre.set_layer(Layer::Top); // Rofi est au-dessus (couche "overlay")
        for bord in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
            fenetre.set_anchor(bord, true);
        }
        fenetre.set_exclusive_zone(-1);
        fenetre.set_keyboard_mode(KeyboardMode::None);

        let clic = gtk::GestureClick::new();
        clic.set_button(0); // tous les boutons de la souris
        let b = boucle.clone();
        clic.connect_pressed(move |_, _, x, y| {
            if *outils::ESSAI {
                eprintln!("[essai] attrape-clic : clic en {x:.0},{y:.0}");
            }
            outils::lancer(&["pkill", "-x", "rofi"]);
            b.quit();
        });
        fenetre.add_controller(clic);
        // Un fond quasi transparent (opacité 1/255, invisible) : une fenêtre GTK 4 qui ne dessine
        // rien n'est jamais montrée par le compositeur, et ne recevrait donc aucun clic.
        let fond = outils::boite(true, 0);
        fond.add_css_class("attrape-clic");
        fenetre.set_child(Some(&fond));
        fenetre.present();
        if *outils::ESSAI {
            eprintln!("[essai] attrape-clic affiché");
        }
    }
    boucle.run();
    glib::ExitCode::SUCCESS
}
