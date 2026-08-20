#!/bin/bash
# Installa Mediateca sul Mac. Uso:
#     bash install.sh
#
# Cosa fa, in ordine:
#   1. verifica ffmpeg (indispensabile per riprodurre e convertire i video)
#   2. verifica gli Xcode Command Line Tools (indispensabili per compilare)
#   3. compila l'app e la installa in ~/Applications/Mediateca.app
#   4. memorizza dentro il bundle il percorso di questa repo, così il
#      pulsante "Aggiorna" dentro l'app sa dove tirare gli aggiornamenti
#   5. apre l'app appena installata
#
# Nessun sudo, nessuna modifica al sistema al di fuori di ~/Applications.

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

# ── 3. Compilazione ─────────────────────────────────────────────────────
echo
bold "► Compilo Mediateca…"
cd "$REPO_DIR/app"
./build.sh

# ── 4. Traccia della repo dentro il bundle ──────────────────────────────
APP="$HOME/Applications/Mediateca.app"
mkdir -p "$APP/Contents/Resources"
printf '%s\n' "$REPO_DIR" > "$APP/Contents/Resources/repo_path"
# Ri-firma il bundle: se non lo facciamo, aggiungere il file rompe la firma
# ad-hoc creata da build.sh e macOS blocca l'apertura con "codice modificato".
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# ── 5. Apre l'app ───────────────────────────────────────────────────────
echo
green "✅ Mediateca è installata in $APP"
echo
bold "► Apro l'app…"
open "$APP"

echo
echo "  Per aggiornarla in futuro basta cliccare “Aggiorna” dentro l'app,"
echo "  oppure rilanciare:   bash install.sh"
echo
