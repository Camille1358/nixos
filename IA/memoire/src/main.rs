//! Archive des conversations avec Claude Code -> mémoire partagée de l'IA locale (Qdrant).
//!
//!   memoire-conversations          ajoute les messages nouveaux depuis la dernière fois
//!   memoire-conversations --tout   efface l'archive déjà rangée et reprend tout depuis le début
//!                                  (à faire après un changement de modèle dans parametres.nix)
//!
//! Lit les conversations que Claude Code enregistre (~/.claude/projects/*/*.jsonl) et range les
//! nouveaux messages dans Qdrant par l'outil "qdrant-store" du serveur MCP mcp-server-qdrant :
//! c'est lui qui calcule les vecteurs, avec le même modèle que pour les agents, qui retrouvent
//! donc ces messages avec "qdrant-find".
//!
//! Gardé : ce que l'utilisateur a écrit, les réponses de Claude, une ligne par action (sa
//! description). Laissé de côté : les résultats bruts des commandes, les réflexions internes,
//! les images. Les secrets reconnaissables (clés "sk-...", clés WireGuard, mots de passe écrits
//! en clair) sont masqués avant d'être rangés.
//!
//! Réglages (variables d'environnement, fournies par IA/home.nix) :
//!   MEMOIRE_SERVEUR   chemin du serveur MCP mcp-server-qdrant (QDRANT_URL, COLLECTION_NAME et
//!                     EMBEDDING_MODEL lui sont transmis tels quels)
//!   MEMOIRE_ETAT      fichier où sont notés les messages déjà rangés
//!   MEMOIRE_SOURCES   dossier des conversations (par défaut : ~/.claude/projects)

use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use regex::Regex;
use serde_json::{Value, json};

const TAILLE: usize = 600; // caractères par souvenir : le modèle ne "lit" qu'environ 128 mots par texte
const SOURCE: &str = "conversation-claude-code"; // étiquette de ces souvenirs dans Qdrant

type Erreur = Box<dyn std::error::Error>;

/// Un message lisible : empreinte, date, auteur, texte, dossier de travail.
struct Message {
    empreinte: String,
    date: String,
    auteur: &'static str,
    texte: String,
    dossier: String,
}

struct Nettoyage {
    secrets: Vec<(Regex, &'static str)>,
    rappel: Regex,
    balises: Vec<Regex>,
    image: Regex,
}

impl Nettoyage {
    fn new() -> Self {
        let r = |motif: &str| Regex::new(motif).expect("motif valide");
        Nettoyage {
            secrets: vec![
                // d'abord "mot de passe = ...", sinon la valeur serait masquée deux fois
                (
                    r(
                        r"(?i)((?:password|passwd|mot de passe|secret|api[_-]?key|private[_-]?key|auth[_-]?token)\s*[:=]\s*)\S+",
                    ),
                    "${1}[masqué]",
                ),
                (r(r"sk-[A-Za-z0-9_-]{16,}"), "[clé masquée]"),
                // clé WireGuard (et autres clés en base64 de 32 octets)
                (
                    r(r"(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{42,43}=($|[^A-Za-z0-9+/=])"),
                    "${1}[clé masquée]${2}",
                ),
            ],
            rappel: r(r"(?s)<system-reminder>.*?</system-reminder>"),
            // (pas de références arrière dans ce moteur : une expression par sorte de balise)
            balises: ["local-command-[a-z]+", "command-[a-z]+", "ide_[a-z]+"]
                .iter()
                .map(|nom| r(&format!(r"(?s)<({nom})>.*?</({nom})>")))
                .collect(),
            image: r(r"\[Image: [^\]]*\]"),
        }
    }

    fn masquer(&self, texte: &str) -> String {
        let mut t = texte.to_owned();
        for (motif, remplacement) in &self.secrets {
            t = motif.replace_all(&t, *remplacement).into_owned();
        }
        t
    }

    fn texte_utilisateur(&self, contenu: &Value) -> String {
        let brut = match contenu {
            Value::String(s) => s.clone(),
            // liste : morceaux de texte, images, résultats d'outils (ces derniers sont ignorés)
            Value::Array(parties) => parties
                .iter()
                .filter(|p| p["type"] == "text")
                .filter_map(|p| p["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n"),
            _ => String::new(),
        };
        let mut t = self.rappel.replace_all(&brut, "").into_owned();
        for balise in &self.balises {
            t = balise.replace_all(&t, "").into_owned();
        }
        let t = self.image.replace_all(&t, "[image]").trim().to_owned();
        if t.starts_with("[Request interrupted") {
            String::new()
        } else {
            t
        }
    }
}

fn texte_claude(contenu: &Value) -> String {
    let Value::Array(parties) = contenu else {
        return contenu.as_str().unwrap_or_default().trim().to_owned();
    };
    let mut lignes = Vec::new();
    for p in parties {
        match p["type"].as_str() {
            Some("text") => lignes.push(p["text"].as_str().unwrap_or_default().to_owned()),
            Some("tool_use") => {
                // une ligne par action : ce qu'elle fait, pas son résultat
                let entree = &p["input"];
                let quoi = entree["description"]
                    .as_str()
                    .or(entree["file_path"].as_str())
                    .map(str::to_owned)
                    .unwrap_or_else(|| {
                        entree["command"]
                            .as_str()
                            .unwrap_or_default()
                            .chars()
                            .take(150)
                            .collect()
                    });
                lignes.push(format!(
                    "[action {} : {quoi}]",
                    p["name"].as_str().unwrap_or("?")
                ));
            }
            _ => {}
        }
    }
    lignes
        .into_iter()
        .filter(|l| !l.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

/// Empreinte stable d'un message (FNV-1a 64 bits) : reconnaît un même message recopié dans
/// une autre conversation (Claude Code recopie l'historique quand une conversation est reprise).
fn empreinte(texte: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for octet in texte.bytes() {
        h ^= u64::from(octet);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

fn messages(fichier: &Path, n: &Nettoyage) -> Vec<Message> {
    let Ok(f) = fs::File::open(fichier) else {
        return Vec::new();
    };
    let mut liste = Vec::new();
    for ligne in BufReader::new(f).lines().map_while(Result::ok) {
        let Ok(e) = serde_json::from_str::<Value>(&ligne) else {
            continue;
        };
        let genre = e["type"].as_str().unwrap_or_default();
        if !matches!(genre, "user" | "assistant") || e["isSidechain"] == true || e["isMeta"] == true
        {
            continue;
        }
        let contenu = &e["message"]["content"];
        if contenu.is_null() || e["uuid"].is_null() {
            continue;
        }
        let (texte, auteur) = if genre == "user" {
            let t = n.texte_utilisateur(contenu);
            let auteur = if t.starts_with("This session is being continued") {
                "Résumé des échanges précédents"
            } else {
                "Utilisateur"
            };
            (t, auteur)
        } else {
            (texte_claude(contenu), "Claude")
        };
        if texte.is_empty() {
            continue;
        }
        let date = e["timestamp"].as_str().unwrap_or_default().to_owned();
        let texte = n.masquer(&texte);
        liste.push(Message {
            empreinte: empreinte(&format!("{date}|{auteur}|{texte}")),
            date,
            auteur,
            texte,
            dossier: e["cwd"].as_str().unwrap_or_default().to_owned(),
        });
    }
    liste
}

/// Coupe un long texte en morceaux d'environ `taille` caractères, entre deux lignes.
fn decouper(texte: &str, taille: usize) -> Vec<String> {
    let mut morceaux = Vec::new();
    let mut courant = String::new();
    for ligne in texte.split_inclusive('\n') {
        let mut ligne: Vec<char> = ligne.chars().collect();
        while ligne.len() > taille {
            // ligne immense : coupée net
            let debut: String = ligne.drain(..taille).collect();
            morceaux.push(std::mem::take(&mut courant) + &debut);
        }
        let ligne: String = ligne.into_iter().collect();
        if courant.chars().count() + ligne.chars().count() > taille && !courant.is_empty() {
            morceaux.push(std::mem::take(&mut courant));
        }
        courant.push_str(&ligne);
    }
    if !courant.trim().is_empty() {
        morceaux.push(courant);
    }
    morceaux
}

/// Regroupe des messages consécutifs en souvenirs d'environ TAILLE caractères :
/// (information, métadonnées, empreintes des messages).
fn souvenirs(nouveaux: &[Message], session: &str) -> Vec<(String, Value, Vec<String>)> {
    let mut resultat = Vec::new();
    let mut groupe: Vec<(&Message, String)> = Vec::new();
    let mut longueur = 0;
    let fermer = |groupe: &[(&Message, String)]| {
        let (debut, fin) = (&groupe[0].0.date, &groupe[groupe.len() - 1].0.date);
        let jour = if debut.is_empty() {
            "date inconnue".to_owned()
        } else {
            debut
                .chars()
                .take(16)
                .collect::<String>()
                .replace('T', " à ")
        };
        let dossier = if groupe[0].0.dossier.is_empty() {
            "?"
        } else {
            groupe[0].0.dossier.as_str()
        };
        let corps: Vec<String> = groupe
            .iter()
            .map(|(m, morceau)| format!("{} : {morceau}", m.auteur))
            .collect();
        // en-tête court : la place compte
        let information = format!("Claude Code, {jour} :\n{}", corps.join("\n"));
        let meta = json!({ "source": SOURCE, "session": session, "dossier": dossier, "debut": debut, "fin": fin });
        (
            information,
            meta,
            groupe.iter().map(|(m, _)| m.empreinte.clone()).collect(),
        )
    };
    for m in nouveaux {
        for morceau in decouper(&m.texte, TAILLE) {
            let n = morceau.chars().count();
            if !groupe.is_empty() && longueur + n > TAILLE {
                resultat.push(fermer(&groupe));
                groupe.clear();
                longueur = 0;
            }
            groupe.push((m, morceau));
            longueur += n;
        }
    }
    if !groupe.is_empty() {
        resultat.push(fermer(&groupe));
    }
    resultat
}

/// Dialogue minimal avec un serveur MCP (JSON-RPC, une ligne par message).
struct ServeurMcp {
    processus: Child,
    entree: ChildStdin,
    sortie: BufReader<ChildStdout>,
    numero: u64,
}

impl ServeurMcp {
    fn lancer(commande: &str) -> Result<Self, Erreur> {
        let mut processus = Command::new(commande)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        let entree = processus.stdin.take().ok_or("pas d'entrée")?;
        let sortie = BufReader::new(processus.stdout.take().ok_or("pas de sortie")?);
        let mut serveur = ServeurMcp {
            processus,
            entree,
            sortie,
            numero: 0,
        };
        serveur.demander(
            "initialize",
            json!({ "protocolVersion": "2025-03-26", "capabilities": {},
                    "clientInfo": { "name": "memoire-conversations", "version": "1" } }),
        )?;
        serveur.envoyer(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))?;
        Ok(serveur)
    }

    fn envoyer(&mut self, message: &Value) -> Result<(), Erreur> {
        writeln!(self.entree, "{message}")?;
        self.entree.flush()?;
        Ok(())
    }

    fn demander(&mut self, methode: &str, parametres: Value) -> Result<Value, Erreur> {
        self.numero += 1;
        let message =
            json!({ "jsonrpc": "2.0", "id": self.numero, "method": methode, "params": parametres });
        self.envoyer(&message)?;
        loop {
            let mut ligne = String::new();
            if self.sortie.read_line(&mut ligne)? == 0 {
                return Err("le serveur MCP de Qdrant s'est arrêté".into());
            }
            let Ok(reponse) = serde_json::from_str::<Value>(&ligne) else {
                continue;
            };
            if reponse["id"] == self.numero {
                if !reponse["error"].is_null() {
                    return Err(reponse["error"].to_string().into());
                }
                return Ok(reponse["result"].clone());
            }
        }
    }

    fn ranger(&mut self, information: &str, meta: &Value) -> Result<(), Erreur> {
        let resultat = self.demander(
            "tools/call",
            json!({ "name": "qdrant-store", "arguments": { "information": information, "metadata": meta } }),
        )?;
        if resultat["isError"] == true {
            return Err(resultat["content"].to_string().into());
        }
        Ok(())
    }

    fn fermer(mut self) {
        drop(self.entree);
        let _ = self.processus.wait();
    }
}

/// --tout : retire de Qdrant les morceaux de conversation déjà rangés (rien d'autre).
fn effacer_archive() -> Result<(), Erreur> {
    let adresse = env::var("QDRANT_URL")?;
    let collection = env::var("COLLECTION_NAME")?;
    let hote = adresse.trim_start_matches("http://").trim_end_matches('/');
    let corps = json!({ "filter": { "must": [{ "key": "metadata.source", "match": { "value": SOURCE } }] } })
        .to_string();
    let mut flux = TcpStream::connect(hote)?;
    write!(
        flux,
        "POST /collections/{collection}/points/delete HTTP/1.1\r\nHost: {hote}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{corps}",
        corps.len()
    )?;
    let mut reponse = String::new();
    flux.read_to_string(&mut reponse)?;
    let code = reponse.split_whitespace().nth(1).unwrap_or("");
    // 404 : la collection n'existe pas encore, rien à effacer
    if code.starts_with('2') || code == "404" {
        Ok(())
    } else {
        Err(format!("Qdrant a répondu {code}").into())
    }
}

fn executer() -> Result<usize, Erreur> {
    let tout = env::args().skip(1).any(|a| a == "--tout");
    let etat_chemin = PathBuf::from(env::var("MEMOIRE_ETAT")?);
    let sources = env::var("MEMOIRE_SOURCES")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env::var("HOME").unwrap_or_default()).join(".claude/projects")
        });
    let mut deja: BTreeSet<String> = BTreeSet::new();
    if !tout {
        if let Ok(etat) =
            fs::read_to_string(&etat_chemin).map(|t| serde_json::from_str::<Value>(&t))
            && let Ok(etat) = etat
        {
            deja = etat["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|m| m.as_str().map(str::to_owned))
                .collect();
        }
    } else {
        effacer_archive()?;
    }

    // Conversations, de la plus ancienne à la plus récente
    let mut fichiers: Vec<(std::time::SystemTime, PathBuf)> = fs::read_dir(&sources)?
        .flatten()
        .filter(|d| d.path().is_dir())
        .flat_map(|d| fs::read_dir(d.path()).into_iter().flatten().flatten())
        .map(|f| f.path())
        .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
        .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
        .collect();
    fichiers.sort();

    let nettoyage = Nettoyage::new();
    let mut serveur: Option<ServeurMcp> = None;
    let mut ranges = 0;
    for (_, fichier) in fichiers {
        let mut nouveaux = Vec::new();
        for m in messages(&fichier, &nettoyage) {
            if deja.insert(m.empreinte.clone()) {
                // insert : aussi pas deux fois dans ce même passage
                nouveaux.push(m);
            }
        }
        if nouveaux.is_empty() {
            continue;
        }
        if serveur.is_none() {
            // le serveur (et son modèle) n'est lancé que s'il y a du nouveau
            serveur = Some(ServeurMcp::lancer(&env::var("MEMOIRE_SERVEUR")?)?);
        }
        let session = fichier
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        for (information, meta, _) in souvenirs(&nouveaux, &session) {
            serveur
                .as_mut()
                .expect("lancé ci-dessus")
                .ranger(&information, &meta)?;
            ranges += 1;
        }
        // noté après chaque conversation : une interruption ne refait pas tout
        if let Some(dossier) = etat_chemin.parent() {
            fs::create_dir_all(dossier)?;
        }
        let provisoire = etat_chemin.with_extension("tmp");
        fs::write(&provisoire, json!({ "messages": deja }).to_string())?;
        fs::rename(&provisoire, &etat_chemin)?;
    }
    if let Some(serveur) = serveur {
        serveur.fermer();
    }
    Ok(ranges)
}

fn main() {
    match executer() {
        Ok(n) => println!("{n} souvenir(s) ajouté(s) à la mémoire partagée."),
        Err(e) => {
            eprintln!("memoire-conversations : {e}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod essais {
    use super::*;

    #[test]
    fn secrets_masques() {
        let n = Nettoyage::new();
        assert_eq!(
            n.masquer("cle sk-abcdefghijklmnopqrstuv fin"),
            "cle [clé masquée] fin"
        );
        assert_eq!(
            n.masquer("PrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28="),
            "PrivateKey = [masqué]"
        );
        assert_eq!(n.masquer("password: hunter2"), "password: [masqué]");
        assert_eq!(n.masquer("rien de secret"), "rien de secret");
    }

    #[test]
    fn rappels_retires() {
        let n = Nettoyage::new();
        let t = n.texte_utilisateur(&json!(
            "avant <system-reminder>x\ny</system-reminder> après"
        ));
        assert_eq!(t, "avant  après");
        assert_eq!(
            n.texte_utilisateur(&json!("[Request interrupted by user]")),
            ""
        );
    }

    #[test]
    fn decoupage() {
        let long = "a".repeat(1300);
        let morceaux = decouper(&long, 600);
        assert_eq!(
            morceaux.iter().map(|m| m.len()).collect::<Vec<_>>(),
            [600, 600, 100]
        );
        assert_eq!(decouper("ligne 1\nligne 2\n", 600), ["ligne 1\nligne 2\n"]);
    }

    #[test]
    fn empreinte_stable() {
        assert_eq!(empreinte(""), "cbf29ce484222325");
        assert_ne!(empreinte("a"), empreinte("b"));
    }
}
