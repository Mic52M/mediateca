#!/bin/bash
# Installa Mediateca sul Mac. Uso:
#     bash install.sh
#
# Cosa fa, in ordine:
#   1. verifica ffmpeg (indispensabile per riprodurre e convertire i video)
#   2. verifica gli Xcode Command Line Tools (indispensabili per compilare)
#   3. installa o aggiorna VibraVid in ~/Documents/VibraVid (alla versione
#      provata con questa app) e prepara il suo ambiente Python: è il
#      motore di download della funzione "Scarica"
#   4. compila l'app e la installa in ~/Applications/Mediateca.app
#   5. memorizza dentro il bundle il percorso di questa repo, così il
#      pulsante "Aggiorna" dentro l'app sa dove tirare gli aggiornamenti
#   6. apre l'app appena installata
#
# Nessun sudo, nessuna modifica al sistema fuori da ~/Applications e
# ~/Documents/VibraVid.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

echo
bold "═══════════════════════════════════════════════════════"
bold "  Installazione Mediateca"
bold "═══════════════════════════════════════════════════════"
echo

# ── 1. ffmpeg ────────────────────────────────────────────────────────────
if command -v ffmpeg >/dev/null 2>&1; then
    green "✓ ffmpeg trovato ($(ffmpeg -version 2>&1 | head -1 | awk '{print $3}'))"
else
    red "✗ ffmpeg non trovato."
    echo "  Serve per riprodurre MKV, generare le anteprime e convertire i video."
    echo
    if command -v brew >/dev/null 2>&1; then
        yellow "  Ho trovato Homebrew: posso installarlo io con questo comando"
        yellow "    brew install ffmpeg"
        read -r -p "  Vuoi che lo faccia adesso? [S/n] " reply
        case "${reply:-s}" in
            [sS]|[sS][iI]|"") brew install ffmpeg ;;
            *)  echo "  Ok, installalo manualmente e rilancia lo script."; exit 1 ;;
        esac
    else
        echo "  Installa prima Homebrew (https://brew.sh), poi:"
        echo "    brew install ffmpeg"
        echo "  Infine rilancia questo script."
        exit 1
    fi
fi

# ── 2. Xcode Command Line Tools (contengono swiftc) ─────────────────────
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 \
    && command -v swiftc >/dev/null 2>&1; then
    green "✓ Toolchain Swift disponibile"
else
    red "✗ Servono gli Xcode Command Line Tools per compilare."
    echo "  Sto avviando l'installazione — se compare una finestra, clicca “Installa”."
    xcode-select --install 2>/dev/null || true
    echo
    yellow "  Attendi la fine dell'installazione, poi rilancia:  bash install.sh"
    exit 1
fi

# ── 3. VibraVid: motore di download online ──────────────────────────────
# Repo Python separata, clonata in ~/Documents/VibraVid (il percorso che l'app
# cerca di default). Si usa il progetto originale, bloccato alla versione con
# cui Mediateca è stata provata: una versione più recente potrebbe cambiare
# l'output che l'app legge. Per passare a una più nuova si cambia VIBRAVID_COMMIT.
VIBRAVID_DIR="${VIBRAVID_DIR:-$HOME/Documents/VibraVid}"
VIBRAVID_REPO="https://github.com/AstraeLabs/VibraVid.git"
VIBRAVID_COMMIT="ed6282fb013436d7326f0fbb4a5c045c5614fd29"   # v1.5.0, 2026-11-10

# Porta la cartella di VibraVid esattamente al commit indicato. I file di
# configurazione dell'utente (Conf/config.toml, Conf/login.toml) sono tracciati
# da git: li mettiamo da parte e li rimettiamo, così le sue impostazioni restano.
vibravid_checkout() {
    local tmp; tmp="$(mktemp -d)"
    cp "$VIBRAVID_DIR/Conf/config.toml" "$VIBRAVID_DIR/Conf/login.toml" "$tmp/" 2>/dev/null || true
    git -C "$VIBRAVID_DIR" fetch --quiet --depth 1 "$VIBRAVID_REPO" "$VIBRAVID_COMMIT"
    git -C "$VIBRAVID_DIR" checkout --quiet --force -B main FETCH_HEAD
    for f in config.toml login.toml; do
        [ -f "$tmp/$f" ] && cp "$tmp/$f" "$VIBRAVID_DIR/Conf/$f"
    done
    rm -rf "$tmp"
}

echo
if ! command -v python3 >/dev/null 2>&1; then
    red "✗ python3 non trovato sul sistema."
    echo "  Su macOS 14+ dovrebbe esserci già; se manca:  brew install python@3.13"
    exit 1
fi

if [ ! -d "$VIBRAVID_DIR/.git" ]; then
    bold "► Scarico VibraVid (motore di download online)…"
    mkdir -p "$VIBRAVID_DIR"
    git -C "$VIBRAVID_DIR" init --quiet
    vibravid_checkout
    green "✓ VibraVid installato"

elif [ ! -f "$VIBRAVID_DIR/Conf/config.toml" ]; then
    # Installazione con la vecchia versione (1.2.x): configurazione in JSON e
    # sito ormai bloccato (errore 403). Si aggiorna lasciando intatti i download
    # (cartella Video) e l'ambiente Python, e si salva tutto il resto.
    yellow "► VibraVid è una versione vecchia: la aggiorno."
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [ -d "$VIBRAVID_DIR/Conf" ]; then
        cp -R "$VIBRAVID_DIR/Conf" "$VIBRAVID_DIR/Conf.backup-$stamp"
        echo "  copia della vecchia configurazione: $VIBRAVID_DIR/Conf.backup-$stamp"
    fi
    git -C "$VIBRAVID_DIR" branch -f "backup-prima-dell-aggiornamento-$stamp" HEAD 2>/dev/null || true
    echo "  codice precedente conservato nel ramo git: backup-prima-dell-aggiornamento-$stamp"
    vibravid_checkout
    green "✓ VibraVid aggiornato (i video già scaricati non sono stati toccati)"

else
    green "✓ VibraVid già presente in $VIBRAVID_DIR"
    if [ "$(git -C "$VIBRAVID_DIR" rev-parse HEAD 2>/dev/null)" != "$VIBRAVID_COMMIT" ]; then
        yellow "  riporto VibraVid alla versione provata con questa app"
        vibravid_checkout
    fi
fi

# Ambiente Python + dipendenze. pip salta quello che è già a posto, quindi si
# può rieseguire senza costi: serve a recuperare le librerie nuove dopo un
# aggiornamento di VibraVid.
if [ ! -x "$VIBRAVID_DIR/venv/bin/python" ]; then
    bold "► Creo l'ambiente Python di VibraVid (una volta sola, ~1-2 minuti)…"
    python3 -m venv "$VIBRAVID_DIR/venv"
    "$VIBRAVID_DIR/venv/bin/pip" install --quiet --upgrade pip
fi
"$VIBRAVID_DIR/venv/bin/pip" install --quiet -r "$VIBRAVID_DIR/requirements.txt"
# curl_cffi >= 0.15 non si importa con Python di conda/pyenv su macOS
# (symbol not found '_CFRelease'): si blocca alla 0.14.
"$VIBRAVID_DIR/venv/bin/pip" install --quiet "curl_cffi<0.15"
green "✓ Ambiente Python di VibraVid pronto"

# Primo avvio: VibraVid scarica l'elenco dei siti (Conf/domains.json), che la
# schermata Impostazioni → Domini mostra. Senza questo la tabella sarebbe vuota.
( cd "$VIBRAVID_DIR" && "$VIBRAVID_DIR/venv/bin/python" -c \
    "from VibraVid.utils import config_manager as m; m._ensure_domains()" >/dev/null 2>&1 ) || true
if [ -f "$VIBRAVID_DIR/Conf/domains.json" ]; then
    green "✓ Elenco dei siti scaricato"
else
    yellow "  elenco dei siti non ancora scaricato (internet assente?): lo farà VibraVid al primo download"
fi

# ── 4. Compilazione ─────────────────────────────────────────────────────
echo
bold "► Compilo Mediateca…"
cd "$REPO_DIR/app"
./build.sh

# ── 5. Traccia della repo dentro il bundle ──────────────────────────────
APP="$HOME/Applications/Mediateca.app"
mkdir -p "$APP/Contents/Resources"
printf '%s\n' "$REPO_DIR" > "$APP/Contents/Resources/repo_path"
# Ri-firma il bundle: se non lo facciamo, aggiungere il file rompe la firma
# ad-hoc creata da build.sh e macOS blocca l'apertura con "codice modificato".
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# ── 6. Apre l'app ───────────────────────────────────────────────────────
echo
green "✅ Mediateca è installata in $APP"
echo
bold "► Apro l'app…"
open "$APP"

echo
echo "  Per aggiornarla in futuro basta cliccare “Aggiorna” dentro l'app,"
echo "  oppure rilanciare:   bash install.sh"
echo
