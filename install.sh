#!/bin/bash
# Installa Mediateca sul Mac. Uso:
#     bash install.sh
#
# Cosa fa, in ordine:
#   1. verifica ffmpeg (indispensabile per riprodurre e convertire i video)
#   2. verifica gli Xcode Command Line Tools (indispensabili per compilare)
#   3. clona VibraVid in ~/Documents/VibraVid e prepara il venv Python
#      (motore di download della funzione "Scarica" nell'app)
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
# È una repo Python separata. La cloniamo in ~/Documents/VibraVid (path che
# l'app cerca di default) e installiamo le dipendenze in un venv locale.
VIBRAVID_DIR="$HOME/Documents/VibraVid"
# Fork privato con il preset di lingua integrato. Se sostituisci l'URL
# assicurati che la repo contenga cli/command/track_preset.py, altrimenti
# il pannello Scarica non passa più il flag --tracks.
VIBRAVID_REPO="https://github.com/Mic52M/VibraVid.git"

echo
if [ -d "$VIBRAVID_DIR/.git" ]; then
    green "✓ VibraVid già presente in $VIBRAVID_DIR"
    # Aggiorniamo silenziosamente: se il fork ha nuovi commit (ad es. seed
    # dei domini o correzioni), l'utente li riceve senza doverli tirare a mano.
    # Se ci sono modifiche locali non committate lasciamo perdere, per non
    # rovinare eventuali personalizzazioni.
    if [ -z "$(git -C "$VIBRAVID_DIR" status --porcelain 2>/dev/null)" ]; then
        git -C "$VIBRAVID_DIR" pull --quiet --ff-only 2>/dev/null \
            && green "  aggiornato all'ultima versione" \
            || yellow "  aggiornamento saltato (pull non fast-forward)"
    else
        yellow "  ci sono modifiche locali non committate: aggiornamento saltato"
    fi
    if [ -x "$VIBRAVID_DIR/venv/bin/python" ]; then
        green "  venv Python già configurato"
    fi
else
    bold "► Preparo VibraVid (motore di download online)…"

    if ! command -v python3 >/dev/null 2>&1; then
        red "✗ python3 non trovato sul sistema."
        echo "  Su macOS 14+ dovrebbe esserci già; se manca:  brew install python@3.13"
        exit 1
    fi
    green "✓ Python $(python3 --version | awk '{print $2}')"

    git clone --depth 1 "$VIBRAVID_REPO" "$VIBRAVID_DIR"
fi

# venv + dipendenze Python. Se il venv c'è già saltiamo, altrimenti lo
# creiamo e installiamo requirements una volta sola.
if [ ! -x "$VIBRAVID_DIR/venv/bin/python" ]; then
    bold "► Creo l'ambiente Python di VibraVid (una volta sola, ~1-2 minuti)…"
    python3 -m venv "$VIBRAVID_DIR/venv"
    "$VIBRAVID_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$VIBRAVID_DIR/venv/bin/pip" install --quiet -r "$VIBRAVID_DIR/requirements.txt"
    green "✓ VibraVid pronto"
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
