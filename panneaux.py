#!/usr/bin/env python3
# Panneaux de la barre et du bureau :
#
#   panneaux calendrier | session | son | reduites | capture FICHIER   panneaux déroulants
#   panneaux reseau          réseau et Bluetooth (comme KDE Plasma)
#   panneaux notifications   historique des notifications, par application
#   panneaux alttab          miniatures de l'Alt+Tab (la logique est dans Hyprland)
#
# Relancer la même commande referme le panneau. Un clic n'importe où en dehors,
# ou la touche Échap, le referme aussi.
# Couleurs, police et réglages viennent de desktop-home.nix (fichier JSON désigné
# par la variable PANNEAUX_THEME) : rien n'est à régler ici.
#
# "gi" (PyGObject, la liaison Python de GTK) n'est pas installé dans le système :
# Nix le fournit seulement au programme une fois construit (voir "panneaux" dans
# desktop-home.nix). L'éditeur ne peut donc pas le trouver ; la ligne suivante lui
# dit de ne pas le signaler comme une erreur.
# pyright: reportMissingImports=false, reportMissingModuleSource=false
import calendar
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import date, datetime, timedelta
from datetime import time as heure_du_jour

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, GtkLayerShell, Pango  # noqa: E402

# -----------------------------------------------------------------------------
# Réglages reçus de Nix
# -----------------------------------------------------------------------------
with open(os.environ["PANNEAUX_THEME"], encoding="utf-8") as fichier:
    THEME = json.load(fichier)
C = THEME["couleurs"]

# Si ce fichier existe, la veille automatique de l'ordinateur est désactivée
# (même convention que le script "veille-auto" de desktop-home.nix).
DRAPEAU = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "veille-auto-desactivee")

MARGE = 12  # espace autour du panneau et à l'intérieur, en pixels

# Mode essai (lancer avec PANNEAUX_ESSAI=1) : les commandes qui changent quelque chose
# (éteindre, verrouiller, couper le réseau, connecter un appareil...) sont seulement
# affichées, jamais exécutées. Les commandes qui ne font que lire restent permises.
ESSAI = bool(os.environ.get("PANNEAUX_ESSAI"))
COMMANDES_SENSIBLES = ("systemctl", "hyprlock")
# Pour ces outils, seuls ces mots-là (dans la commande) changent quelque chose :
VERBES_SENSIBLES = {
    "hyprctl": {"dispatch", "eval"},
    "nmcli": {"on", "off", "up", "down", "connect", "disconnect", "delete"},
    "rfkill": {"block", "unblock"},
    "bluetoothctl": {"pair", "trust", "connect", "disconnect", "power", "remove"},
    "makoctl": {"-t", "-a", "-r", "dismiss"},
}

MOIS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
        "septembre", "octobre", "novembre", "décembre"]
MOIS_COURTS = ["janv.", "févr.", "mars", "avr.", "mai", "juin",
               "juil.", "août", "sept.", "oct.", "nov.", "déc."]
JOURS = ["lu", "ma", "me", "je", "ve", "sa", "di"]

# Icônes de la police Nerd Font, désignées par leur code
# (liste : https://www.nerdfonts.com/cheat-sheet).
ICONES = {
    "precedent": "\uf053",
    "suivant": "\uf054",
    "eteindre": "\uf011",
    "redemarrer": "\uf021",
    "veille": "\uf186",
    "sablier": "\uf253",
    "annuler": "\uf00d",
    "cafe": "\uf0f4",
    "lit": "\uf236",
    "cadenas": "\uf023",
    "sortir": "\uf08b",
    "son": "\uf028",
    "son_coupe": "\uf026",
    "micro": "\uf130",
    "micro_coupe": "\uf131",
    "coche": "\uf00c",
    "reglages": "\uf1de",
    "fenetre": "\uf2d0",
    "tout": "\uf2d2",
    "copier": "\uf0c5",
    "enregistrer": "\uf0c7",
    "dossier": "\uf07c",
    "wifi": "\uf1eb",
    "avion": "\uf072",
    "bluetooth": "\uf293",
    "ethernet": "\U000f0200",
    "recherche": "\uf002",
    "casque": "\uf025",
    "clavier": "\uf11c",
    "souris": "\uf245",
    "telephone": "\uf10b",
    "manette": "\uf11b",
    "cloche": "\uf0f3",
    "cloche_barree": "\uf1f6",
    "poubelle": "\uf1f8",
}

CSS = f"""
* {{ font-family: "{THEME['police']}"; font-size: 14px; }}
window {{ background: transparent; }}
#panneau {{
    background: alpha(#{C['bg']}, 0.94);
    border: 2px solid #{C['cyan']};
    border-radius: 12px;
    color: #{C['text']};
}}
button {{
    background: transparent; background-image: none; border: none; box-shadow: none;
    text-shadow: none; color: #{C['text']}; border-radius: 8px; padding: 7px 10px;
    min-height: 0; min-width: 0;
}}
button:hover, button:focus {{ background: #{C['surface2']}; color: #{C['cyan']}; }}
button.danger:hover, button.danger:focus {{ color: #{C['red']}; }}
button.choisi {{ color: #{C['cyan']}; }}
button.titre-cal {{ font-weight: bold; color: #{C['cyan']}; padding: 7px 6px; }}
button.jour {{ padding: 6px 0; min-width: 34px; border-radius: 8px; }}
.semaine {{ color: #{C['violet']}; padding: 6px 0; min-width: 34px; }}
button.hors {{ color: #{C['muted']}; }}
button.jour:hover, button.jour:focus {{ background: #{C['surface2']}; color: #{C['cyan']}; }}
button.auj, button.auj:hover, button.auj:focus {{
    background: #{C['cyan']}; color: #{C['bg']}; font-weight: bold;
}}
button.auj:hover {{ background: #{C['text']}; }}
.titre {{ color: #{C['violet']}; font-size: 12px; }}
.discret {{ color: #{C['muted']}; font-size: 12px; }}
.erreur {{ color: #{C['red']}; font-size: 12px; }}
.icone {{ min-width: 22px; }}
entry {{
    background: #{C['surface']}; color: #{C['text']}; border: 1px solid #{C['surface2']};
    border-radius: 8px; padding: 6px 10px; caret-color: #{C['cyan']}; box-shadow: none;
}}
entry:focus {{ border-color: #{C['cyan']}; }}
scale {{ padding: 4px 0; }}
scale trough {{ background: #{C['surface2']}; min-height: 6px; border-radius: 3px; border: none; }}
scale highlight {{ background: #{C['cyan']}; border-radius: 3px; border: none; }}
scale slider {{
    background: #{C['text']}; min-width: 14px; min-height: 14px; border-radius: 7px;
    border: none; box-shadow: none; margin: -5px;
}}
separator {{ background: #{C['surface2']}; min-height: 1px; margin: 4px 0; }}

/* Réseau : grandes tuiles Wi-Fi / Mode avion / Bluetooth, comme KDE Plasma */
button.tuile {{
    background: #{C['surface']}; border: 1px solid #{C['surface2']};
    border-radius: 10px; padding: 10px 4px;
}}
button.tuile:hover, button.tuile:focus {{ background: #{C['surface2']}; }}
button.tuile.allumee {{
    background: alpha(#{C['cyan']}, 0.18); border-color: #{C['cyan']}; color: #{C['cyan']};
}}
button.tuile:disabled {{ opacity: 0.4; }}
.grosse-icone {{ font-size: 20px; }}
button.petit {{ padding: 3px 8px; font-size: 12px; color: #{C['muted']}; }}
button.petit:hover {{ color: #{C['red']}; }}

/* Notifications */
.appli {{ font-weight: bold; color: #{C['cyan']}; }}
.notif-titre {{ font-weight: bold; }}
.corps {{ color: #{C['muted']}; font-size: 13px; }}

/* Alt+Tab : une carte par fenêtre */
.carte {{ background: alpha(#{C['surface']}, 0.9); border: 2px solid transparent; border-radius: 12px; }}
.carte.choisie {{ border-color: #{C['cyan']}; background: alpha(#{C['cyan']}, 0.14); }}
.miniature {{ background: #{C['bg']}; border-radius: 8px; }}
"""


# -----------------------------------------------------------------------------
# Outils communs
# -----------------------------------------------------------------------------
def retenue(commande):
    """En mode essai, affiche une commande sensible au lieu de l'exécuter."""
    if not ESSAI:
        return False
    sensible = commande[0] in COMMANDES_SENSIBLES or \
        bool(VERBES_SENSIBLES.get(commande[0], set()) & set(commande[1:]))
    if sensible:
        print("[essai] non exécuté :", *commande, file=sys.stderr, flush=True)
    return bool(sensible)


# Les outils répondent en anglais (et non dans la langue du système) : leurs réponses
# ("enabled", "blocked"...) peuvent ainsi être lues de façon sûre.
ENV_OUTILS = dict(os.environ, LC_ALL="C.UTF-8")


def lancer(*commande):
    """Lance un programme sans attendre sa fin, détaché du panneau."""
    if retenue(commande):
        return
    try:
        subprocess.Popen(commande, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass  # programme introuvable : on ne fait rien plutôt que de planter le panneau


def executer(*commande, delai=5):
    """Lance un programme, attend sa fin (au plus `delai` secondes).
    Renvoie (réussi, texte affiché)."""
    if retenue(commande):
        return True, ""
    try:
        r = subprocess.run(commande, capture_output=True, text=True, timeout=delai,
                           check=False, env=ENV_OUTILS)
    except (OSError, subprocess.SubprocessError):
        return False, ""
    return r.returncode == 0, r.stdout


def en_fond(travail, puis=None):
    """Exécute travail() sans figer l'affichage, puis puis(résultat) dans l'affichage.
    Pour les actions lentes : connexion Wi-Fi, recherche Bluetooth, captures..."""
    def fil():
        resultat = travail()
        if puis is not None:
            GLib.idle_add(lambda: puis(resultat) and False)
    threading.Thread(target=fil, daemon=True).start()


def appli_installee(nom_fichier):
    """Description (.desktop) d'une application installée, ou None si elle n'existe pas."""
    try:
        return Gio.DesktopAppInfo.new(nom_fichier)
    except TypeError:  # PyGObject signale ainsi une application introuvable
        return None


def icone_appli(nom, taille):
    """Image de l'application (d'après son nom ou sa classe de fenêtre), ou None."""
    theme = Gtk.IconTheme.get_default()
    icones = []
    for essai in dict.fromkeys((nom, nom.lower())):  # sans doublon, dans l'ordre
        info = appli_installee(f"{essai}.desktop")
        if info is not None and info.get_icon() is not None:
            icones.append(info.get_icon())
    if not icones:
        for groupe in Gio.DesktopAppInfo.search(nom):
            for ident in groupe:
                info = appli_installee(ident)
                if info is not None and info.get_icon() is not None:
                    icones.append(info.get_icon())
                    break
            if icones:
                break
    icones.append(Gio.ThemedIcon.new(nom.lower()))
    for icone in icones:
        trouvee = theme.lookup_by_gicon(icone, taille, Gtk.IconLookupFlags.FORCE_SIZE)
        if trouvee is not None:
            try:
                return Gtk.Image.new_from_pixbuf(trouvee.load_icon())
            except GLib.Error:
                continue
    return None


def notifier(titre, texte, urgent=False):
    options = ["-u", "critical"] if urgent else []
    lancer("notify-send", *options, titre, texte)


def vider(conteneur):
    for enfant in conteneur.get_children():
        conteneur.remove(enfant)


def etiquette(texte, *classes, centre=False, largeur_max=None):
    e = Gtk.Label(label=texte)
    e.set_xalign(0.5 if centre else 0)
    if largeur_max:  # texte trop long : coupé avec "…"
        e.set_ellipsize(Pango.EllipsizeMode.END)
        e.set_max_width_chars(largeur_max)
    for classe in classes:
        e.get_style_context().add_class(classe)
    return e


def bouton(texte, action, *classes, icone=None, largeur_max=None):
    """Bouton plat. `action` est une fonction sans argument, appelée au clic."""
    b = Gtk.Button()
    b.set_relief(Gtk.ReliefStyle.NONE)
    if icone is None:
        b.set_label(texte)
    else:
        boite = Gtk.Box(spacing=10)
        boite.pack_start(etiquette(icone, "icone", centre=True), False, False, 0)
        boite.pack_start(etiquette(texte, largeur_max=largeur_max), True, True, 0)
        b.add(boite)
    for classe in classes:
        b.get_style_context().add_class(classe)

    def au_clic(_bouton):
        action()

    def au_survol(widget, _evenement):
        # La sélection suit la souris : survoler un bouton lui donne le "curseur".
        widget.grab_focus()
        return False

    b.connect("clicked", au_clic)
    b.connect("enter-notify-event", au_survol)
    return b


# =============================================================================
# Agenda
# =============================================================================
class Calendrier(Gtk.Box):
    """Trois vues dans le même cadre : les jours du mois, les 12 mois, 12 années."""

    def __init__(self, _app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        aujourdhui = date.today()
        self.an, self.mois = aujourdhui.year, aujourdhui.month
        self.vue = "jours"  # "jours", "mois" ou "annees"
        self.premiere_annee = self.an - 5  # première année montrée dans la vue "annees"

        self.bouton_mois = bouton("", lambda: self.basculer_vue("mois"), "titre-cal")
        self.bouton_an = bouton("", lambda: self.basculer_vue("annees"), "titre-cal")
        titre = Gtk.Box()
        titre.pack_start(self.bouton_mois, False, False, 0)
        titre.pack_start(self.bouton_an, False, False, 0)

        entete = Gtk.Box(spacing=2)
        entete.pack_start(bouton(ICONES["precedent"], lambda: self.decaler(-1)), False, False, 0)
        entete.pack_end(bouton(ICONES["suivant"], lambda: self.decaler(1)), False, False, 0)
        entete.set_center_widget(titre)
        self.pack_start(entete, False, False, 0)

        self.zone = Gtk.Box()
        self.zone.set_size_request(290, 250)  # taille fixe : le panneau ne saute pas
        self.pack_start(self.zone, True, True, 0)
        self.dessiner()

    def decaler(self, sens):
        """Flèches : un mois, une année ou une page d'années, selon la vue affichée."""
        if self.vue == "jours":
            numero = self.mois - 1 + sens  # 0 à 11, peut déborder d'un cran
            self.an += numero // 12
            self.mois = numero % 12 + 1
        elif self.vue == "mois":
            self.an += sens
        else:
            self.premiere_annee += 12 * sens
        self.dessiner()

    def basculer_vue(self, vue):
        """Clic sur le mois ou l'année : ouvre la grille de choix, ou revient aux jours."""
        self.vue = "jours" if self.vue == vue else vue
        if self.vue == "annees":
            self.premiere_annee = self.an - 5
        self.dessiner()

    def choisir_mois(self, mois):
        self.mois, self.vue = mois, "jours"
        self.dessiner()

    def choisir_an(self, an):
        self.an, self.vue = an, "jours"
        self.dessiner()

    def dessiner(self):
        self.bouton_mois.set_label(MOIS[self.mois - 1])
        self.bouton_an.set_label(str(self.an))
        vider(self.zone)
        grille = Gtk.Grid(column_homogeneous=True, row_homogeneous=True,
                          column_spacing=2, row_spacing=2)
        grille.set_hexpand(True)
        grille.set_vexpand(True)
        if self.vue == "jours":
            self.remplir_jours(grille)
        elif self.vue == "mois":
            choix = [(MOIS_COURTS[i], i + 1) for i in range(12)]
            self.remplir_choix(grille, choix, self.mois, self.choisir_mois)
        else:
            annees = range(self.premiere_annee, self.premiere_annee + 12)
            choix = [(str(an), an) for an in annees]
            self.remplir_choix(grille, choix, self.an, self.choisir_an)
        self.zone.pack_start(grille, True, True, 0)
        self.zone.show_all()

    def remplir_jours(self, grille):
        for colonne, nom in enumerate(JOURS):
            grille.attach(etiquette(nom, "semaine", centre=True), colonne, 0, 1, 1)

        semaines = calendar.Calendar(firstweekday=0).monthdatescalendar(self.an, self.mois)
        while len(semaines) < 6:  # toujours 6 lignes, quel que soit le mois
            dernier_jour = semaines[-1][-1]
            semaines.append([dernier_jour + timedelta(days=n) for n in range(1, 8)])

        aujourdhui = date.today()
        for ligne, semaine in enumerate(semaines, start=1):
            for colonne, jour in enumerate(semaine):
                classes = ["jour"]
                if jour.month != self.mois:
                    classes.append("hors")  # jour du mois d'avant ou d'après : grisé
                if jour == aujourdhui:
                    classes.append("auj")
                # Un bouton (sans action) plutôt qu'un simple texte : il réagit au survol.
                case = bouton(str(jour.day), lambda: None, *classes)
                grille.attach(case, colonne, ligne, 1, 1)

    @staticmethod
    def remplir_choix(grille, choix, actuel, action):
        """Grille de 3 colonnes de boutons (mois ou années)."""
        for position, (texte, valeur) in enumerate(choix):
            classes = ["choisi"] if valeur == actuel else []
            b = bouton(texte, lambda v=valeur: action(v), *classes)
            grille.attach(b, position % 3, position // 3, 1, 1)


# =============================================================================
# Menu session
# =============================================================================
def arret_prevu():
    """Moment de l'arrêt programmé, ou None s'il n'y en a pas."""
    _, texte = executer("busctl", "get-property", "org.freedesktop.login1",
                        "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                        "ScheduledShutdown")
    champs = texte.split()  # exemple : (st) "poweroff" 1791234567000000
    if len(champs) < 3 or champs[1] == '""':
        return None
    try:
        return datetime.fromtimestamp(int(champs[2]) / 1_000_000)
    except (ValueError, OSError):
        return None


def analyser_moment(saisie):
    """Transforme le texte tapé en date et heure, ou None si ce n'est pas compris.

    Formes acceptées : "23:30", "7h30", "7h", "90" (dans 90 minutes),
    "demain 7:00", "après-demain 9h", "24/12 18:00", "2026-12-24 18:00".
    """
    texte = saisie.strip().lower()
    maintenant = datetime.now()
    try:
        if texte.isdigit():
            return maintenant + timedelta(minutes=int(texte))

        jour = None  # date précise, si elle est donnée
        dans_jours = 0  # sinon : 0 = aujourd'hui, 1 = demain, 2 = après-demain

        m = re.match(r"(apr[eè]s-demain|demain)\s+(.*)", texte)
        if m:
            dans_jours = 2 if m[1].startswith("apr") else 1
            texte = m[2]

        m = re.match(r"(\d{4})-(\d{1,2})-(\d{1,2})\s+(.*)", texte)
        if m:
            jour = date(int(m[1]), int(m[2]), int(m[3]))
            texte = m[4]
        else:
            m = re.match(r"(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\s+(.*)", texte)
            if m:
                jour = date(int(m[3] or maintenant.year), int(m[2]), int(m[1]))
                texte = m[4]

        m = re.fullmatch(r"(\d{1,2})\s*(?:[:h]\s*(\d{2})?)?", texte)  # 23:30, 7h30, 7h, 7
        if not m:
            return None
        heure = heure_du_jour(int(m[1]), int(m[2] or 0))
        date_seule = jour is None and dans_jours == 0
        if jour is None:
            jour = maintenant.date() + timedelta(days=dans_jours)
        moment = datetime.combine(jour, heure)
        if date_seule and moment <= maintenant:
            moment += timedelta(days=1)  # une heure déjà passée aujourd'hui = demain
        return moment if moment > maintenant else None
    except ValueError:  # 25:00, 31/02...
        return None


class Session(Gtk.Box):
    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.app = app
        self.saisie = None  # champ "éteindre à", créé par construire()
        self.aide = None
        self.revelateur = None
        self.set_size_request(320, -1)
        self.construire()

    def construire(self):
        vider(self)
        self.add(bouton("Éteindre", lambda: self.quitter_et_lancer("systemctl", "poweroff"),
                        "danger", icone=ICONES["eteindre"]))
        self.add(bouton("Redémarrer", lambda: self.quitter_et_lancer("systemctl", "reboot"),
                        icone=ICONES["redemarrer"]))
        self.add(bouton("Mettre en veille", lambda: self.quitter_et_lancer("systemctl", "suspend"),
                        icone=ICONES["veille"]))
        self.add(Gtk.Separator())

        prevu = arret_prevu()
        if prevu:
            self.add(bouton(f"Annuler l'arrêt de {prevu:%H:%M}", self.annuler_arret,
                            icone=ICONES["annuler"]))
        else:
            self.add(bouton("Programmer un arrêt…", self.montrer_saisie, icone=ICONES["sablier"]))
            self.add(self.zone_de_saisie())

        if os.path.exists(DRAPEAU):
            self.add(bouton("Veille auto de l'ordi : désactivée", self.basculer_veille,
                            "choisi", icone=ICONES["cafe"]))
        else:
            self.add(bouton("Veille auto de l'ordi : activée", self.basculer_veille,
                            icone=ICONES["lit"]))
        self.add(Gtk.Separator())
        self.add(bouton("Verrouiller", lambda: self.quitter_et_lancer("hyprlock"),
                        icone=ICONES["cadenas"]))
        self.add(bouton("Déconnexion", lambda: self.quitter_et_lancer("hyprctl", "dispatch", "hl.dsp.exit()"),
                        icone=ICONES["sortir"]))
        self.show_all()

    def zone_de_saisie(self):
        """Champ "éteindre à", caché tant qu'on n'a pas cliqué sur "Programmer un arrêt"."""
        self.saisie = Gtk.Entry()
        self.saisie.set_placeholder_text("23:30  ·  90  ·  demain 7:00")
        self.saisie.connect("activate", self.programmer_arret)  # touche Entrée
        self.aide = etiquette("Heure, minutes, ou date : 24/12 18:00", "discret")
        boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        boite.set_margin_start(42)
        boite.set_margin_end(6)
        boite.set_margin_bottom(6)
        boite.add(self.saisie)
        boite.add(self.aide)
        self.revelateur = Gtk.Revealer()
        self.revelateur.add(boite)
        return self.revelateur

    def quitter_et_lancer(self, *commande):
        self.app.fermer()
        lancer(*commande)

    @staticmethod
    def rafraichir_barre():
        """Demande à la barre de mettre à jour son témoin (tasse de café, sablier)."""
        lancer("pkill", "-RTMIN+8", "waybar")

    def montrer_saisie(self):
        ouvert = not self.revelateur.get_reveal_child()
        self.revelateur.set_reveal_child(ouvert)
        if ouvert:
            self.saisie.grab_focus()

    def programmer_arret(self, _champ):
        moment = analyser_moment(self.saisie.get_text())
        if moment is None:
            self.aide.set_text("Pas compris, ou déjà passé. Exemple : 23:30")
            self.aide.get_style_context().add_class("erreur")
            return
        reussi, _ = executer("systemctl", "poweroff", "--no-wall",
                             f"--when={moment:%Y-%m-%d %H:%M:%S}")
        if reussi:
            notifier("Arrêt programmé", f"L'ordinateur s'éteindra le {moment:%d/%m à %H:%M}.")
        else:
            notifier("Arrêt programmé", "Impossible de programmer l'arrêt.", urgent=True)
        self.rafraichir_barre()
        self.app.fermer()

    def annuler_arret(self):
        executer("systemctl", "poweroff", "--no-wall", "--when=cancel")
        notifier("Arrêt programmé", "Arrêt annulé.")
        self.rafraichir_barre()
        self.construire()

    def basculer_veille(self):
        if os.path.exists(DRAPEAU):
            os.remove(DRAPEAU)
            minutes = THEME["ordiEnVeilleApres"]
            notifier("Veille automatique", f"Réactivée : veille après {minutes} min d'inactivité.")
        else:
            with open(DRAPEAU, "w", encoding="utf-8"):
                pass  # fichier vide : seule sa présence compte
            notifier("Veille automatique",
                     "Désactivée : l'ordinateur reste allumé (l'écran s'éteint toujours).")
        self.rafraichir_barre()
        self.construire()


# =============================================================================
# Son
# =============================================================================
def pactl(*arguments):
    """Interroge le serveur de son. Renvoie le texte affiché par pactl."""
    return executer("pactl", *arguments)[1]


def pactl_liste(quoi):
    """Liste des "sinks" (sorties), "sources" (entrées) ou "sink-inputs" (applications)."""
    try:
        return json.loads(pactl("-f", "json", "list", quoi) or "[]")
    except ValueError:
        return []


def volume_de(element):
    """Volume en pourcentage d'une sortie, d'un micro ou d'une application."""
    try:
        premier_canal = next(iter(element["volume"].values()))
        return int(premier_canal["value_percent"].strip().rstrip("%"))
    except (KeyError, StopIteration, ValueError, AttributeError):
        return 0


class Son(Gtk.Box):
    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.app = app
        self.set_size_request(400, -1)
        self.construire()

    def construire(self):
        vider(self)
        self.partie_sortie()
        self.partie_micro()
        self.partie_applications()
        self.add(Gtk.Separator())
        self.add(bouton("Mélangeur complet", self.ouvrir_melangeur, icone=ICONES["reglages"]))
        self.show_all()

    def partie_sortie(self):
        sorties = pactl_liste("sinks")
        nom_actuel = pactl("get-default-sink").strip()
        actuelle = next((s for s in sorties if s.get("name") == nom_actuel), None)

        self.add(etiquette("SORTIE", "titre"))
        if actuelle:
            self.add(self.ligne_volume(
                actuelle, ("son", "son_coupe"),
                regler=lambda v: lancer("pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{v}%"),
                couper=lambda: self.pactl_puis_redessiner(
                    "set-sink-mute", "@DEFAULT_SINK@", "toggle")))

        for s in sorties:  # choix de la sortie : casque, enceintes, écran...
            nom = s.get("name", "?")
            description = s.get("description")
            if not description or description == "(null)":
                description = nom
            choisie = nom == nom_actuel
            self.add(bouton(
                description,
                lambda n=nom: self.pactl_puis_redessiner("set-default-sink", n),
                *(["choisi"] if choisie else []),
                icone=ICONES["coche"] if choisie else " ", largeur_max=38))

    def partie_micro(self):
        nom_actuel = pactl("get-default-source").strip()
        micro = next((s for s in pactl_liste("sources") if s.get("name") == nom_actuel), None)
        if not micro:
            return
        self.add(Gtk.Separator())
        self.add(etiquette("MICRO", "titre"))
        self.add(self.ligne_volume(
            micro, ("micro", "micro_coupe"),
            regler=lambda v: lancer("pactl", "set-source-volume", "@DEFAULT_SOURCE@", f"{v}%"),
            couper=lambda: self.pactl_puis_redessiner(
                "set-source-mute", "@DEFAULT_SOURCE@", "toggle")))

    def partie_applications(self):
        applis = pactl_liste("sink-inputs")
        if not applis:
            return
        self.add(Gtk.Separator())
        self.add(etiquette("APPLICATIONS", "titre"))
        for appli in applis:
            numero = str(appli["index"])
            infos = appli.get("properties", {})
            nom = etiquette(infos.get("application.name") or infos.get("media.name") or "?",
                            largeur_max=40)
            nom.set_margin_start(10)
            self.add(nom)
            self.add(self.ligne_volume(
                appli, ("son", "son_coupe"),
                regler=lambda v, n=numero: lancer("pactl", "set-sink-input-volume", n, f"{v}%"),
                couper=lambda n=numero: self.pactl_puis_redessiner(
                    "set-sink-input-mute", n, "toggle")))

    def ligne_volume(self, element, icones, regler, couper):
        """Une ligne : bouton couper/rétablir, curseur de volume, pourcentage."""
        coupe = bool(element.get("mute"))
        valeur = min(volume_de(element), 100)

        curseur = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        curseur.set_value(valeur)
        curseur.set_hexpand(True)
        curseur.set_draw_value(False)
        pourcent = etiquette(f"{valeur} %", "discret")
        pourcent.set_width_chars(5)
        pourcent.set_xalign(1)

        # Pendant qu'on fait glisser le curseur, il change des dizaines de fois par
        # seconde : on n'envoie le volume au système qu'une fois toutes les 40 ms.
        envoi = {"en_attente": False}

        def envoyer():
            envoi["en_attente"] = False
            regler(int(curseur.get_value()))
            return False  # ne pas répéter

        def au_changement(_curseur):
            pourcent.set_text(f"{int(curseur.get_value())} %")
            if not envoi["en_attente"]:
                envoi["en_attente"] = True
                GLib.timeout_add(40, envoyer)

        curseur.connect("value-changed", au_changement)

        ligne = Gtk.Box(spacing=4)
        ligne.pack_start(bouton(ICONES[icones[1] if coupe else icones[0]], couper,
                                *(["danger"] if coupe else [])), False, False, 0)
        ligne.pack_start(curseur, True, True, 0)
        ligne.pack_start(pourcent, False, False, 0)
        return ligne

    def pactl_puis_redessiner(self, *arguments):
        pactl(*arguments)
        self.construire()

    def ouvrir_melangeur(self):
        self.app.fermer()
        lancer("pavucontrol")


# =============================================================================
# Fenêtres réduites (bouton "réduire" des fenêtres, ou Super+N)
# =============================================================================
ESPACE_REDUITES = "special:reduites"


def hyprland(*arguments):
    """Interroge Hyprland ; renvoie la réponse JSON décodée, ou None."""
    try:
        return json.loads(executer("hyprctl", "-j", *arguments)[1] or "null")
    except ValueError:
        return None


def fenetres_reduites():
    return [f for f in hyprland("clients") or []
            if f.get("workspace", {}).get("name") == ESPACE_REDUITES]


class Reduites(Gtk.Box):
    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.app = app
        self.set_size_request(340, -1)
        self.construire()

    def construire(self):
        vider(self)
        fenetres = fenetres_reduites()
        self.add(etiquette("FENÊTRES RÉDUITES", "titre"))
        if not fenetres:
            self.add(etiquette("Aucune. Bouton « réduire » d'une fenêtre, ou Super+N.", "discret"))
        for f in fenetres:
            texte = f.get("title") or f.get("class") or "?"
            self.add(bouton(texte, lambda a=f["address"]: self.restaurer(a),
                            icone=ICONES["fenetre"], largeur_max=40))
        if len(fenetres) > 1:
            self.add(Gtk.Separator())
            self.add(bouton("Tout ramener", self.tout_restaurer, icone=ICONES["tout"]))
        self.show_all()

    @staticmethod
    def ramener(adresse):
        """Ramène la fenêtre sur l'espace de travail affiché et lui donne la main."""
        actif = (hyprland("activeworkspace") or {}).get("id", 1)
        executer("hyprctl", "dispatch",
                 f'hl.dsp.window.move({{ window = "address:{adresse}", workspace = {actif} }})')
        executer("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{adresse}" }})')

    def restaurer(self, adresse):
        self.app.fermer()
        self.ramener(adresse)
        lancer("pkill", "-RTMIN+9", "waybar")

    def tout_restaurer(self):
        self.app.fermer()
        for f in fenetres_reduites():
            self.ramener(f["address"])
        lancer("pkill", "-RTMIN+9", "waybar")


# =============================================================================
# Capture d'écran : aperçu, puis copier / enregistrer / enregistrer sous
# =============================================================================
def dossier_captures():
    """~/Images/Captures (le dossier Images suit la langue du système)."""
    images = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_PICTURES) \
        or os.path.expanduser("~/Images")
    dossier = os.path.join(images, "Captures")
    os.makedirs(dossier, exist_ok=True)
    return dossier


class Capture(Gtk.Box):
    """L'image vient d'être prise dans un fichier temporaire (en mémoire vive).
    Copier ne laisse aucune trace : le fichier est effacé juste après."""

    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.app = app
        self.fichier = app.parametre
        self.garder = False  # True une fois l'image enregistrée : ne pas l'effacer

        apercu = GdkPixbuf.Pixbuf.new_from_file(self.fichier)
        largeur, hauteur = apercu.get_width(), apercu.get_height()
        echelle = min(1.0, 760 / largeur, 460 / hauteur)  # aperçu réduit pour tenir à l'écran
        if echelle < 1.0:
            apercu = apercu.scale_simple(max(1, int(largeur * echelle)), max(1, int(hauteur * echelle)),
                                         GdkPixbuf.InterpType.BILINEAR)
        self.add(etiquette(f"CAPTURE  ·  {largeur} × {hauteur}", "titre"))
        self.add(Gtk.Image.new_from_pixbuf(apercu))

        actions = Gtk.Box(spacing=6)
        actions.set_halign(Gtk.Align.CENTER)
        actions.add(bouton("Copier", self.copier, icone=ICONES["copier"]))
        actions.add(bouton("Enregistrer", self.enregistrer, icone=ICONES["enregistrer"]))
        actions.add(bouton("Enregistrer sous…", self.enregistrer_sous, icone=ICONES["dossier"]))
        actions.add(bouton("Annuler", self.app.fermer, "danger", icone=ICONES["annuler"]))
        self.add(actions)

    def copier(self):
        with open(self.fichier, "rb") as image:
            # wl-copy lit l'image puis reste en arrière-plan pour la fournir au collage
            subprocess.run(["wl-copy", "--type", "image/png"], stdin=image, check=False)
        notifier("Capture", "Copiée dans le presse-papiers.")
        self.app.fermer()

    def ranger(self, destination):
        shutil.move(self.fichier, destination)  # marche aussi vers un autre disque
        self.garder = True
        notifier("Capture enregistrée", destination)

    def enregistrer(self):
        nom = datetime.now().strftime("Capture_%Y-%m-%d_%H-%M-%S.png")
        self.ranger(os.path.join(dossier_captures(), nom))
        self.app.fermer()

    def enregistrer_sous(self):
        # Le choix du fichier se fait dans une fenêtre normale : on retire d'abord le panneau
        # (qui couvre tout l'écran), sans effacer l'image.
        self.garder = True
        self.app.hold()  # le programme ne doit pas se terminer pendant le choix
        self.app.fermer()
        choix = Gtk.FileChooserDialog(title="Enregistrer la capture",
                                      action=Gtk.FileChooserAction.SAVE)
        choix.add_buttons("Annuler", Gtk.ResponseType.CANCEL,
                          "Enregistrer", Gtk.ResponseType.ACCEPT)
        choix.set_do_overwrite_confirmation(True)
        choix.set_current_folder(dossier_captures())
        choix.set_current_name(datetime.now().strftime("Capture_%Y-%m-%d_%H-%M-%S.png"))
        if choix.run() == Gtk.ResponseType.ACCEPT:
            self.ranger(choix.get_filename())
        else:
            os.remove(self.fichier)
        choix.destroy()
        self.app.release()

    def a_la_fermeture(self):
        if not self.garder and os.path.exists(self.fichier):
            os.remove(self.fichier)


# =============================================================================
# "Attrape-clic" du lanceur d'applications (Rofi)
# =============================================================================
# Rofi ne se ferme pas quand on clique ailleurs. On place donc, juste sous lui, une surface
# transparente qui couvre l'écran (barre comprise) : un clic dessus ferme Rofi. Elle ne prend
# pas le clavier, qui reste à Rofi. Lancée et arrêtée par le script "lanceur" (desktop-home.nix).
def attrape_clic():
    fenetre = Gtk.Window()
    GtkLayerShell.init_for_window(fenetre)
    GtkLayerShell.set_namespace(fenetre, "attrape-clic")
    GtkLayerShell.set_layer(fenetre, GtkLayerShell.Layer.TOP)  # Rofi est au-dessus (OVERLAY)
    for bord in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                 GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
        GtkLayerShell.set_anchor(fenetre, bord, True)
    GtkLayerShell.set_exclusive_zone(fenetre, -1)
    GtkLayerShell.set_keyboard_mode(fenetre, GtkLayerShell.KeyboardMode.NONE)
    visuel = fenetre.get_screen().get_rgba_visual()
    if visuel:
        fenetre.set_visual(visuel)
    fenetre.set_app_paintable(True)

    def clic(_widget, _evenement):
        lancer("pkill", "-x", "rofi")
        Gtk.main_quit()
        return True

    zone = Gtk.EventBox()
    zone.set_visible_window(False)
    zone.connect("button-press-event", clic)
    fenetre.add(zone)
    fenetre.connect("destroy", Gtk.main_quit)
    fenetre.show_all()
    Gtk.main()


# =============================================================================
# Réseau et Bluetooth (clic sur le module réseau de la barre), comme KDE Plasma
# =============================================================================
def nmcli(*arguments, delai=5):
    return executer("nmcli", *arguments, delai=delai)


def champs(ligne):
    """Découpe une ligne de "nmcli -t" (les ":" contenus dans les valeurs sont écrits "\\:")."""
    return [c.replace("\\:", ":") for c in re.split(r"(?<!\\):", ligne)]


def radios_coupees():
    """Pour chaque type de radio ("wlan", "bluetooth"...) : True si elle est coupée."""
    _, texte = executer("rfkill", "--noheadings", "--output", "TYPE,SOFT")
    etats = {}
    for ligne in texte.splitlines():
        morceaux = ligne.split()
        if len(morceaux) == 2:
            etats[morceaux[0]] = etats.get(morceaux[0], True) and morceaux[1] == "blocked"
    return etats


def reseaux_wifi():
    """Réseaux Wi-Fi visibles, un par nom : le réseau connecté d'abord, puis le plus fort."""
    _, texte = nmcli("-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list",
                     "--rescan", "no")
    reseaux = {}
    for ligne in texte.splitlines():
        c = champs(ligne)
        if len(c) < 4 or not c[1]:
            continue  # réseau caché (sans nom)
        actif, nom, signal = c[0] == "*", c[1], int(c[2] or 0)
        ancien = reseaux.get(nom)
        if ancien is None or actif or (signal > ancien["signal"] and not ancien["actif"]):
            reseaux[nom] = {"nom": nom, "signal": signal, "actif": actif,
                            "securise": c[3] not in ("", "--")}
    return sorted(reseaux.values(), key=lambda r: (not r["actif"], -r["signal"]))


def appareils_bluetooth(filtre=None):
    """[(adresse, nom)] des appareils Bluetooth ("Paired" = associés, "Connected" = connectés)."""
    _, texte = executer("bluetoothctl", "devices", *([filtre] if filtre else []))
    appareils = []
    for m in re.finditer(r"^Device ([0-9A-F:]{17}) (.+)$", texte, re.M):
        if not re.fullmatch(r"([0-9A-F]{2}-){5}[0-9A-F]{2}", m[2]):  # appareil sans nom
            appareils.append((m[1], m[2]))
    return appareils


ICONES_BLUETOOTH = {"audio-headset": "casque", "audio-headphones": "casque", "audio-card": "son",
                    "input-keyboard": "clavier", "input-mouse": "souris", "phone": "telephone",
                    "input-gaming": "manette"}


def icone_bluetooth(adresse):
    _, texte = executer("bluetoothctl", "info", adresse)
    m = re.search(r"Icon: (\S+)", texte)
    return ICONES[ICONES_BLUETOOTH.get(m[1] if m else "", "bluetooth")]


# État des radios avant le mode avion, pour le retrouver en le quittant
AVANT_AVION = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "avant-mode-avion.json")


class Reseau(Gtk.Box):
    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.app = app
        self.set_size_request(410, -1)
        self.mot_de_passe_pour = None  # réseau Wi-Fi dont on tape le mot de passe
        self.en_cours = set()  # actions lancées et pas encore terminées
        self.recherche = False  # recherche d'appareils Bluetooth en cours
        self.trouves = []  # appareils Bluetooth trouvés par la recherche
        self.construire()
        en_fond(lambda: nmcli("device", "wifi", "rescan", delai=10), lambda _r: self.rafraichir())
        self.minuteur = GLib.timeout_add_seconds(5, self.rafraichir)

    def a_la_fermeture(self):
        GLib.source_remove(self.minuteur)

    def rafraichir(self):
        # pas pendant la saisie d'un mot de passe (elle serait effacée)
        if self.app.vue is self and self.mot_de_passe_pour is None and not self.en_cours:
            self.construire()
        return True

    def action(self, cle, travail, echec="L'opération n'a pas abouti."):
        """Lance une action en arrière-plan ; le panneau affiche "…" en attendant."""
        self.en_cours.add(cle)
        self.construire()

        def fini(resultat):
            self.en_cours.discard(cle)
            if not resultat[0]:
                notifier("Réseau", echec)
            if self.app.vue is self:
                self.construire()
        en_fond(travail, fini)

    # --- Construction ---------------------------------------------------------
    def construire(self):
        vider(self)
        radios = radios_coupees()
        avion = bool(radios) and all(radios.values())
        cartes = [champs(ligne) for ligne in nmcli("-t", "-f", "DEVICE,TYPE,STATE", "device")[1].splitlines()]
        carte_wifi = next((c[0] for c in cartes if len(c) > 1 and c[1] == "wifi"), None)
        wifi_allume = nmcli("radio", "wifi")[1].strip() == "enabled" and not radios.get("wlan")
        bt_present = "bluetooth" in radios
        bt_allume = bt_present and not radios["bluetooth"] and \
            "Powered: yes" in executer("bluetoothctl", "show")[1]

        tuiles = Gtk.Box(spacing=6, homogeneous=True)
        if carte_wifi:
            tuiles.add(self.tuile("Wi-Fi", "wifi", wifi_allume, self.basculer_wifi, not avion))
        tuiles.add(self.tuile("Mode avion", "avion", avion, self.basculer_avion))
        if bt_present:
            tuiles.add(self.tuile("Bluetooth", "bluetooth", bt_allume, self.basculer_bluetooth,
                                  not avion))
        self.add(tuiles)

        self.section_filaire(cartes)
        if carte_wifi and wifi_allume:
            self.section_wifi(carte_wifi)
        if bt_allume:
            self.section_bluetooth()
        self.add(Gtk.Separator())
        self.add(bouton("Paramètres réseau avancés", self.parametres, icone=ICONES["reglages"]))
        self.show_all()

    def tuile(self, texte, icone, allumee, action, active=True):
        b = Gtk.Button()
        b.set_relief(Gtk.ReliefStyle.NONE)
        boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        boite.add(etiquette(ICONES[icone], "grosse-icone", centre=True))
        boite.add(etiquette(texte, centre=True))
        b.add(boite)
        b.get_style_context().add_class("tuile")
        if allumee:
            b.get_style_context().add_class("allumee")
        b.set_sensitive(active)
        b.connect("clicked", lambda _b: action(not allumee))
        return b

    def ligne(self, texte, icone, active, connecter, deconnecter, detail="", attente=False):
        """Une connexion : clic = s'y connecter ; "Déconnecter" à droite si elle est active."""
        rangee = Gtk.Box(spacing=4)
        if attente:
            texte += "  · connexion…"
        principal = bouton(texte, (lambda: None) if active or attente else connecter,
                           *(["choisi"] if active else []), icone=icone, largeur_max=26)
        rangee.pack_start(principal, True, True, 0)
        if detail:
            rangee.pack_start(etiquette(detail, "discret"), False, False, 0)
        if active:
            rangee.pack_end(bouton("Déconnecter", deconnecter, "petit"), False, False, 0)
        return rangee

    def section_filaire(self, cartes):
        if not any(len(c) > 1 and c[1] == "ethernet" for c in cartes):
            return
        self.add(etiquette("FILAIRE", "titre"))
        profils = [c for c in (champs(ligne) for ligne in nmcli(
            "-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show")[1].splitlines())
            if len(c) > 3 and c[2] == "802-3-ethernet"]
        if not profils:
            self.add(etiquette("Aucune connexion filaire enregistrée.", "discret"))
        for nom, uuid, _type, carte in (p[:4] for p in profils):
            self.add(self.ligne(
                nom, ICONES["ethernet"], bool(carte),
                connecter=lambda u=uuid: self.action(
                    f"eth:{u}", lambda: nmcli("connection", "up", "uuid", u, delai=30)),
                deconnecter=lambda c=carte: self.action(
                    f"eth:{c}", lambda: nmcli("device", "disconnect", c, delai=15)),
                attente=f"eth:{uuid}" in self.en_cours))

    def section_wifi(self, carte):
        self.add(Gtk.Separator())
        self.add(etiquette("WI-FI", "titre"))
        enregistres = {c[0] for c in (champs(ligne) for ligne in nmcli(
            "-t", "-f", "NAME,TYPE", "connection", "show")[1].splitlines())
            if len(c) > 1 and c[1] == "802-11-wireless"}
        reseaux = reseaux_wifi()[:8]
        if not reseaux:
            self.add(etiquette("Recherche des réseaux…", "discret"))
        for r in reseaux:
            nom = r["nom"]
            detail = f"{r['signal']} %" + (f"  {ICONES['cadenas']}" if r["securise"] else "")
            self.add(self.ligne(
                nom, ICONES["wifi"], r["actif"],
                connecter=lambda n=nom, s=r["securise"]: self.connecter_wifi(n, s, enregistres),
                deconnecter=lambda: self.action(
                    "wifi", lambda: nmcli("device", "disconnect", carte, delai=15)),
                detail=detail, attente=f"wifi:{nom}" in self.en_cours))
            if self.mot_de_passe_pour == nom:
                saisie = Gtk.Entry()
                saisie.set_visibility(False)
                saisie.set_placeholder_text(f"Mot de passe de « {nom} », puis Entrée")
                saisie.set_margin_start(34)
                saisie.connect("activate", lambda e, n=nom: self.connecter_avec_mot_de_passe(
                    n, e.get_text()))
                self.add(saisie)
                GLib.idle_add(lambda s=saisie: s.grab_focus() and False)

    def section_bluetooth(self):
        self.add(Gtk.Separator())
        self.add(etiquette("BLUETOOTH", "titre"))
        connectes = {a for a, _ in appareils_bluetooth("Connected")}
        associes = appareils_bluetooth("Paired")
        if not associes:
            self.add(etiquette("Aucun appareil associé.", "discret"))
        for adresse, nom in associes:
            self.add(self.ligne(
                nom, icone_bluetooth(adresse), adresse in connectes,
                connecter=lambda a=adresse: self.action(
                    f"bt:{a}", lambda: executer("bluetoothctl", "connect", a, delai=20),
                    "Impossible de se connecter : l'appareil est-il allumé et à portée ?"),
                deconnecter=lambda a=adresse: self.action(
                    f"bt:{a}", lambda: executer("bluetoothctl", "disconnect", a, delai=10)),
                attente=f"bt:{adresse}" in self.en_cours))
        deja = {a for a, _ in associes}
        nouveaux = [(a, n) for a, n in self.trouves if a not in deja]
        if nouveaux:
            self.add(etiquette("À PROXIMITÉ — clic pour associer", "titre"))
        for adresse, nom in nouveaux:
            texte = nom + ("  · association…" if f"bt:{adresse}" in self.en_cours else "")
            self.add(bouton(texte, lambda a=adresse: self.associer(a),
                            icone=ICONES["bluetooth"], largeur_max=34))
        self.add(bouton("Recherche en cours… (10 s)" if self.recherche
                        else "Rechercher des appareils", self.rechercher,
                        icone=ICONES["recherche"]))

    # --- Actions --------------------------------------------------------------
    def basculer_wifi(self, allumer):
        def travail():
            if allumer:
                executer("rfkill", "unblock", "wlan")
            return nmcli("radio", "wifi", "on" if allumer else "off")
        self.action("radio-wifi", travail)

    def basculer_avion(self, activer):
        def travail():
            if activer:
                with open(AVANT_AVION, "w", encoding="utf-8") as f:
                    json.dump(radios_coupees(), f)  # pour tout remettre comme avant
                return executer("rfkill", "block", "all")
            try:
                with open(AVANT_AVION, encoding="utf-8") as f:
                    avant = json.load(f)
            except (OSError, ValueError):
                avant = {}
            for radio in ("wlan", "bluetooth", "wwan"):
                if not avant.get(radio, False):
                    executer("rfkill", "unblock", radio)
            if not avant.get("wlan", False):
                nmcli("radio", "wifi", "on")
            return True, ""
        self.action("avion", travail)

    def basculer_bluetooth(self, allumer):
        def travail():
            if not allumer:
                return executer("rfkill", "block", "bluetooth")
            executer("rfkill", "unblock", "bluetooth")
            time.sleep(1.5)  # le temps que l'adaptateur Bluetooth réapparaisse
            return executer("bluetoothctl", "power", "on")
        self.action("radio-bt", travail)

    def connecter_wifi(self, nom, securise, enregistres):
        if nom in enregistres:
            self.action(f"wifi:{nom}", lambda: nmcli("connection", "up", "id", nom, delai=40))
        elif not securise:
            self.action(f"wifi:{nom}", lambda: nmcli("device", "wifi", "connect", nom, delai=40))
        else:
            self.mot_de_passe_pour = nom  # réseau protégé jamais utilisé : demander le mot de passe
            self.construire()

    def connecter_avec_mot_de_passe(self, nom, mot_de_passe):
        self.mot_de_passe_pour = None
        self.action(f"wifi:{nom}",
                    lambda: nmcli("device", "wifi", "connect", nom, "password", mot_de_passe,
                                  delai=40),
                    "Connexion impossible : mot de passe incorrect, ou réseau hors de portée.")

    def rechercher(self):
        if self.recherche:
            return
        self.recherche = True
        self.construire()

        def travail():
            executer("bluetoothctl", "--timeout", "10", "scan", "on", delai=15)
            return appareils_bluetooth()

        def fini(trouves):
            self.recherche = False
            self.trouves = trouves
            if self.app.vue is self:
                self.construire()
        en_fond(travail, fini)

    def associer(self, adresse):
        def travail():
            executer("bluetoothctl", "--agent", "NoInputNoOutput", "pair", adresse, delai=30)
            executer("bluetoothctl", "trust", adresse)
            return executer("bluetoothctl", "connect", adresse, delai=20)
        self.action(f"bt:{adresse}", travail,
                    "Association impossible : l'appareil est-il en mode appairage ?")

    def parametres(self):
        self.app.fermer()
        lancer("nm-connection-editor")


# =============================================================================
# Notifications (cloche de la barre) : historique, groupé par application
# =============================================================================
# Le journal est rempli par le service "journal-notifications" (startup.nix), qui note
# chaque notification avec sa date et son heure, une par ligne.
DOSSIER_NOTIFS = os.path.join(GLib.get_user_state_dir(), "notifications")
JOURNAL_NOTIFS = os.path.join(DOSSIER_NOTIFS, "journal.jsonl")
VU_NOTIFS = os.path.join(DOSSIER_NOTIFS, "vu")  # date de la dernière ouverture du panneau
NOTIFS_GARDEES = 300


def ecrire_notifications(notifications):
    os.makedirs(DOSSIER_NOTIFS, exist_ok=True)
    provisoire = JOURNAL_NOTIFS + ".tmp"
    with open(provisoire, "w", encoding="utf-8") as f:
        for n in notifications:
            f.write(json.dumps(n, ensure_ascii=False) + "\n")
    os.replace(provisoire, JOURNAL_NOTIFS)


def lire_notifications():
    try:
        with open(JOURNAL_NOTIFS, encoding="utf-8") as f:
            lignes = f.read().splitlines()
    except OSError:
        return []
    notifications = []
    for ligne in lignes:
        try:
            notifications.append(json.loads(ligne))
        except ValueError:
            continue
    if len(notifications) > NOTIFS_GARDEES * 2:  # le journal ne grossit pas sans fin
        notifications = notifications[-NOTIFS_GARDEES:]
        ecrire_notifications(notifications)
    return notifications


def sans_balises(texte):
    """Texte brut : sans les balises de mise en forme (<b>...) ni les codes HTML (&amp;)."""
    return html.unescape(re.sub(r"<[^>]*>", "", texte or "")).strip()


def ne_pas_deranger():
    return "do-not-disturb" in executer("makoctl", "mode")[1].split()


class Notifications(Gtk.Box):
    PAR_APPLI = 5  # notifications affichées par application (les plus récentes)

    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.app = app
        self.set_size_request(450, -1)
        self.construire()
        # Tout est maintenant "vu" : la cloche de la barre n'affiche plus de nombre
        os.makedirs(DOSSIER_NOTIFS, exist_ok=True)
        with open(VU_NOTIFS, "w", encoding="utf-8") as f:
            f.write(str(int(time.time())))
        self.rafraichir_barre()

    @staticmethod
    def rafraichir_barre():
        lancer("pkill", "-RTMIN+10", "waybar")

    def construire(self):
        vider(self)
        dnd = ne_pas_deranger()
        entete = Gtk.Box(spacing=6)
        entete.pack_start(etiquette("NOTIFICATIONS", "titre"), True, True, 0)
        entete.pack_end(bouton("Ne pas déranger", self.basculer_ne_pas_deranger,
                               *(["choisi"] if dnd else []),
                               icone=ICONES["cloche_barree" if dnd else "cloche"]), False, False, 0)
        self.add(entete)

        notifications = lire_notifications()
        if not notifications:
            self.add(etiquette("Aucune notification.", "discret"))
            self.show_all()
            return
        groupes = {}  # application -> ses notifications, la plus récente d'abord
        for n in sorted(notifications, key=lambda n: n.get("t", 0), reverse=True):
            groupes.setdefault(n.get("app") or "Système", []).append(n)

        liste = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for appli, elles in groupes.items():
            liste.add(self.entete_appli(appli))
            for n in elles[:self.PAR_APPLI]:
                liste.add(self.notification(n))
            if len(elles) > self.PAR_APPLI:
                reste = etiquette(f"… et {len(elles) - self.PAR_APPLI} plus anciennes", "discret")
                reste.set_margin_start(30)
                liste.add(reste)
        # Liste à sa taille naturelle ; au-delà de 620 pixels de haut, elle défile.
        defilement = Gtk.ScrolledWindow()
        defilement.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        defilement.add(liste)
        liste.show_all()
        defilement.set_min_content_height(min(liste.get_preferred_height()[1], 620))
        self.add(defilement)
        self.add(Gtk.Separator())
        self.add(bouton("Tout effacer", self.tout_effacer, "danger", icone=ICONES["poubelle"]))
        self.show_all()

    def entete_appli(self, appli):
        rangee = Gtk.Box(spacing=8)
        rangee.set_margin_top(6)
        image = icone_appli(appli, 20) if appli != "Système" else None
        rangee.pack_start(image if image else etiquette(ICONES["cloche"], "icone", centre=True),
                          False, False, 0)
        rangee.pack_start(etiquette(appli, "appli", largeur_max=32), True, True, 0)
        effacer = bouton(ICONES["annuler"], lambda: self.effacer(appli), "petit")
        effacer.set_tooltip_text(f"Effacer les notifications de {appli}")
        rangee.pack_end(effacer, False, False, 0)
        return rangee

    @staticmethod
    def notification(n):
        boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        boite.set_margin_start(30)
        haut = Gtk.Box(spacing=8)
        haut.pack_start(etiquette(sans_balises(n.get("titre")) or "(sans titre)", "notif-titre",
                                  largeur_max=34), True, True, 0)
        quand = datetime.fromtimestamp(n.get("t", 0)).strftime("%d/%m  %H:%M")
        haut.pack_end(etiquette(quand, "discret"), False, False, 0)
        boite.add(haut)
        texte = sans_balises(n.get("texte"))
        if texte:
            corps = etiquette(texte, "corps")
            corps.set_line_wrap(True)
            corps.set_lines(3)
            corps.set_ellipsize(Pango.EllipsizeMode.END)
            corps.set_max_width_chars(52)
            boite.add(corps)
        return boite

    def basculer_ne_pas_deranger(self):
        executer("makoctl", "mode", "-t", "do-not-disturb")
        self.rafraichir_barre()
        self.construire()

    def effacer(self, appli):
        ecrire_notifications([n for n in lire_notifications()
                              if (n.get("app") or "Système") != appli])
        self.construire()

    def tout_effacer(self):
        ecrire_notifications([])
        executer("makoctl", "dismiss", "--all")
        self.construire()


# =============================================================================
# Alt+Tab : miniatures des fenêtres
# =============================================================================
# La logique (ordre des fenêtres, Tab, relâchement d'Alt) est dans Hyprland
# (desktop-home.nix, "AltTab"), pour rester instantanée même en tapotant vite. Hyprland
# écrit l'adresse de la fenêtre choisie dans un petit fichier, que ce panneau suit
# pour encadrer la bonne miniature ; il y écrit "fin" quand le choix est terminé.
FICHIER_ALTTAB = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "alttab-choix")
DOSSIER_MINIATURES = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "alttab-miniatures")


def choix_alttab():
    try:
        with open(FICHIER_ALTTAB, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


class AltTab(Gtk.Box):
    LARGEUR, HAUTEUR = 260, 165  # taille d'une miniature
    PAR_LIGNE = 5

    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.app = app
        self.cartes = {}  # adresse -> carte
        self.choix = None
        fenetres = []
        for f in hyprland("clients") or []:
            espace = f.get("workspace", {}).get("name", "")
            if f.get("mapped", True) and (espace == "special:reduites"
                                          or not espace.startswith("special:")):
                fenetres.append(f)
        fenetres.sort(key=lambda f: f.get("focusHistoryID", 99))

        grille = Gtk.Grid(column_spacing=12, row_spacing=12)
        for i, f in enumerate(fenetres):
            grille.attach(self.carte(f), i % self.PAR_LIGNE, i // self.PAR_LIGNE, 1, 1)
        self.add(grille)
        os.makedirs(DOSSIER_MINIATURES, exist_ok=True)
        for f in fenetres:
            self.miniature(f)
        self.suivre()
        self.minuteur = GLib.timeout_add(30, self.suivre)

    def a_la_fermeture(self):
        GLib.source_remove(self.minuteur)

    def carte(self, f):
        adresse = f["address"]
        boite = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for marge in (boite.set_margin_top, boite.set_margin_bottom,
                      boite.set_margin_start, boite.set_margin_end):
            marge(10)
        cadre = Gtk.Box()
        cadre.set_size_request(self.LARGEUR, self.HAUTEUR)
        cadre.get_style_context().add_class("miniature")
        attente = icone_appli(f.get("class", ""), 64) or etiquette(ICONES["fenetre"], "grosse-icone")
        cadre.set_center_widget(attente)  # remplacée par la miniature dès qu'elle est prête
        boite.add(cadre)

        titre = Gtk.Box(spacing=6)
        petite = icone_appli(f.get("class", ""), 18)
        if petite:
            titre.pack_start(petite, False, False, 0)
        titre.pack_start(etiquette(f.get("title") or f.get("class") or "?", largeur_max=26),
                         True, True, 0)
        boite.add(titre)

        carte = Gtk.EventBox()
        carte.get_style_context().add_class("carte")
        carte.add(boite)
        carte.connect("button-press-event", lambda *_: self.cliquer(adresse))
        carte.cadre = cadre
        self.cartes[adresse] = carte
        return carte

    def miniature(self, f):
        """Capture la fenêtre (même cachée ou sur un autre bureau), sans figer l'affichage."""
        chemin = os.path.join(DOSSIER_MINIATURES, f"{f.get('stableId', 'x')}.jpg")
        carte = self.cartes[f["address"]]

        def travail():
            ok, _ = executer("grim", "-T", str(f.get("stableId")), "-s", "0.3", "-t", "jpeg",
                             "-q", "80", chemin, delai=4)
            return ok and os.path.exists(chemin)

        def fini(reussi):
            if not reussi:
                return
            try:
                image = GdkPixbuf.Pixbuf.new_from_file_at_scale(chemin, self.LARGEUR,
                                                                self.HAUTEUR, True)
            except GLib.Error:
                return
            finally:
                if os.path.exists(chemin):
                    os.remove(chemin)
            if self.app.vue is self:
                carte.cadre.set_center_widget(Gtk.Image.new_from_pixbuf(image))
                carte.cadre.show_all()
        en_fond(travail, fini)

    def suivre(self):
        choix = choix_alttab()
        if choix in ("", "fin"):  # choix terminé (ou annulé) dans Hyprland
            self.app.fermer()
            return False
        if choix != self.choix:
            for adresse, carte in self.cartes.items():
                style = carte.get_style_context()
                if adresse == choix:
                    style.add_class("choisie")
                else:
                    style.remove_class("choisie")
            self.choix = choix
        return True

    def cliquer(self, adresse):
        executer("hyprctl", "eval", f'AltTab.choisir("{adresse}")')
        self.app.fermer()
        return True


# =============================================================================
# Fenêtre commune à tous les panneaux
# =============================================================================
VUES = {"calendrier": Calendrier, "session": Session, "son": Son, "reduites": Reduites,
        "capture": Capture, "reseau": Reseau, "notifications": Notifications,
        "alttab": AltTab}


class Panneaux(Gtk.Application):
    """Une seule instance tourne à la fois : relancer la commande parle à celle-ci."""

    def __init__(self):
        super().__init__(application_id="fr.local.panneaux",
                         flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.fenetre = None
        self.mode = None  # nom du panneau affiché, ou None
        self.vue = None
        self.parametre = None  # 2e argument de la commande (ex. le fichier de la capture)

    def do_startup(self):
        Gtk.Application.do_startup(self)
        style = Gtk.CssProvider()
        style.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), style, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    def do_command_line(self, ligne_de_commande):
        """Appelé à chaque lancement de la commande, même si un panneau est déjà ouvert."""
        arguments = ligne_de_commande.get_arguments()
        demande = arguments[1] if len(arguments) > 1 else ""
        self.parametre = arguments[2] if len(arguments) > 2 else None
        if demande not in VUES:
            print(f"usage : panneaux {' | '.join(VUES)}", file=sys.stderr)
            return 1
        if demande == "alttab":
            # Lancé une fois par Hyprland au premier Alt+Tab ; la suite (Tab, relâchement
            # d'Alt) est suivie par le panneau lui-même. Si le choix est déjà terminé
            # (Alt+Tab très rapide), rien à afficher.
            if self.mode != "alttab" and choix_alttab() not in ("", "fin"):
                self.fermer()
                self.ouvrir("alttab")
            return 0
        deja_affiche = self.mode
        self.fermer()
        if demande == "reduites" and deja_affiche != demande:
            # Une seule fenêtre réduite : le clic sur l'icône la ramène directement,
            # sans passer par la liste (qui ne sert que s'il y en a plusieurs).
            fenetres = fenetres_reduites()
            if len(fenetres) == 1:
                Reduites.ramener(fenetres[0]["address"])
                lancer("pkill", "-RTMIN+9", "waybar")
                return 0
        if deja_affiche != demande:  # même panneau redemandé = on le referme seulement
            self.ouvrir(demande)
        return 0

    def fermer(self):
        if self.vue is not None and hasattr(self.vue, "a_la_fermeture"):
            self.vue.a_la_fermeture()  # ex. effacer une capture ni copiée ni enregistrée
        fenetre, self.fenetre, self.mode, self.vue = self.fenetre, None, None, None
        if fenetre:
            fenetre.destroy()  # plus aucune fenêtre : le programme se termine

    def ouvrir(self, mode):
        if mode == "alttab":
            self.ouvrir_alttab()
            return
        fenetre = Gtk.ApplicationWindow(application=self)

        # Surface transparente qui couvre tout l'écran, au-dessus de tout : c'est elle
        # qui reçoit le clic "en dehors du panneau" et les touches du clavier.
        GtkLayerShell.init_for_window(fenetre)
        GtkLayerShell.set_namespace(fenetre, "panneau")
        GtkLayerShell.set_layer(fenetre, GtkLayerShell.Layer.OVERLAY)
        for bord in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(fenetre, bord, True)
        GtkLayerShell.set_exclusive_zone(fenetre, -1)  # recouvre aussi la barre
        GtkLayerShell.set_keyboard_mode(fenetre, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        visuel = fenetre.get_screen().get_rgba_visual()
        if visuel:
            fenetre.set_visual(visuel)
        fenetre.set_app_paintable(True)

        vue = VUES[mode](self)
        self.vue = vue
        vue.set_margin_top(MARGE)
        vue.set_margin_bottom(MARGE)
        vue.set_margin_start(MARGE)
        vue.set_margin_end(MARGE)

        # Le cadre visible : en haut à droite sous la barre ; au centre pour une capture
        cadre = Gtk.EventBox()
        cadre.set_name("panneau")
        if mode == "capture":
            cadre.set_halign(Gtk.Align.CENTER)
            cadre.set_valign(Gtk.Align.CENTER)
        else:
            cadre.set_halign(Gtk.Align.END)
            cadre.set_valign(Gtk.Align.START)
            cadre.set_margin_top(THEME["hauteurBarre"] + 8)
            cadre.set_margin_end(MARGE)
        cadre.add(vue)
        cadre.connect("button-press-event", self.clic_dans_le_panneau)

        fond = Gtk.EventBox()
        fond.set_visible_window(False)
        fond.add(cadre)
        fond.connect("button-press-event", self.clic_en_dehors)

        fenetre.add(fond)
        fenetre.connect("key-press-event", self.touche)
        self.fenetre, self.mode = fenetre, mode
        fenetre.show_all()
        # Aucun bouton présélectionné à l'ouverture : sinon un appui sur Entrée ou Espace
        # juste après avoir ouvert le menu session éteindrait l'ordinateur.
        fenetre.set_focus(None)

    def ouvrir_alttab(self):
        """Miniatures de l'Alt+Tab : seulement un affichage, au centre de l'écran. Le clavier
        reste à Hyprland, qui gère Tab, les flèches, Échap et le relâchement d'Alt."""
        fenetre = Gtk.ApplicationWindow(application=self)
        GtkLayerShell.init_for_window(fenetre)
        GtkLayerShell.set_namespace(fenetre, "alttab")
        GtkLayerShell.set_layer(fenetre, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_keyboard_mode(fenetre, GtkLayerShell.KeyboardMode.NONE)
        visuel = fenetre.get_screen().get_rgba_visual()
        if visuel:
            fenetre.set_visual(visuel)
        fenetre.set_app_paintable(True)

        vue = AltTab(self)
        for marge in (vue.set_margin_top, vue.set_margin_bottom,
                      vue.set_margin_start, vue.set_margin_end):
            marge(16)
        cadre = Gtk.EventBox()
        cadre.set_name("panneau")
        cadre.add(vue)
        fenetre.add(cadre)
        self.fenetre, self.mode, self.vue = fenetre, "alttab", vue
        fenetre.show_all()

    # Pour ces trois fonctions : renvoyer True = "événement traité, ne pas le transmettre".
    @staticmethod
    def clic_dans_le_panneau(_widget, _evenement):
        return True  # sans cela, le clic remonterait au fond et fermerait le panneau

    def clic_en_dehors(self, _widget, _evenement):
        self.fermer()
        return True

    def touche(self, _widget, evenement):
        if evenement.keyval == Gdk.KEY_Escape:
            self.fermer()
            return True
        return False


if __name__ == "__main__":
    if sys.argv[1:2] == ["attrape"]:
        attrape_clic()  # indépendant des panneaux : plusieurs peuvent coexister
    else:
        sys.exit(Panneaux().run(sys.argv))
