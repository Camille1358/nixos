//! panneaux-barre : les modules de la barre (Waybar) et les petites commandes du bureau
//! (barre.rs), dans un programme sans GTK. La barre en lance un toutes les quelques secondes :
//! sans les bibliothèques graphiques à charger, il démarre en quelques millisecondes et
//! n'occupe que quelques Mo, au lieu d'une vingtaine de millisecondes et 25 Mo.
//!
//!   panneaux-barre capteurs cpu|gpu|ram|temp | notifs | etat | reduites-barre
//!   panneaux-barre volume up|down|mute | veille-auto | capture-ecran [ecran] | lanceur

#[path = "barre.rs"]
mod barre;
#[allow(dead_code)] // la feuille de style ne sert qu'aux panneaux
#[path = "style.rs"]
mod style;
#[allow(dead_code)] // certains outils ne servent qu'aux panneaux
#[path = "systeme.rs"]
mod systeme;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let code = barre::commande(&arguments).unwrap_or_else(|| {
        eprintln!(
            "usage : panneaux-barre capteurs cpu|gpu|ram|temp | notifs | etat | reduites-barre | volume up|down|mute \
             | veille-auto | capture-ecran [ecran] | lanceur"
        );
        2
    });
    std::process::exit(code);
}
