# Mediateca

Lettore multimediale nativo per macOS che organizza video locali in serie e
stagioni, ricorda il punto esatto in cui hai interrotto ogni episodio e converte
in automatico i formati che il sistema non riproduce (MKV, AVI, WebM…).

Pensato per guardare contenuti già scaricati con un'esperienza in stile Netflix,
ma con file propri.

## Requisiti

- macOS 14 o successivo (Apple Silicon)
- Xcode / toolchain Swift (per compilare)
- [ffmpeg](https://ffmpeg.org) per la conversione e la generazione delle durate
  dei formati non nativi:

  ```
  brew install ffmpeg
  ```

## Compilazione

```
cd app
./build.sh
```

Lo script compila l'app, genera l'icona, la firma in modalità ad-hoc e la
installa in `~/Applications/Mediateca.app`.

## Come funziona

### Libreria
- **Aggiungi serie** (⌘N): scegli gli episodi, dai un titolo e una stagione.
  Numero di episodio e stagione vengono riconosciuti automaticamente dai nomi
  dei file (es. `S01E04`, `Ep 04`).
- Puoi trascinare file o cartelle direttamente sulla finestra.
- Ogni serie può avere più stagioni, selezionabili da un menu a tendina.
- Gli episodi si riordinano con le frecce, il trascinamento o il menu contestuale
  (ordina per numero, inverti, rinumera), e si possono spostare tra stagioni.
- I file restano dove sono: la libreria memorizza solo il percorso, non copia i
  video. "Rimuovi dalla libreria" non cancella i file.

### Riproduzione
- Player nativo AVKit con Picture-in-Picture, AirPlay e schermo intero.
- La posizione viene salvata di continuo: riaprendo un episodio riparte dal punto
  esatto in cui l'avevi lasciato.
- Riga "Continua a guardare", badge "visto", avvio automatico dell'episodio
  successivo anche a cavallo tra stagioni.
- Durante la visione l'interfaccia sparisce e ricompare al movimento del mouse o
  alla pressione di un tasto.
- I sottotitoli incorporati vengono attivati automaticamente (preferenza
  italiano → inglese → prima traccia disponibile).

### Conversione
- I file non riproducibili dal sistema (MKV, AVI, WebM…) vengono convertiti in
  MP4 automaticamente all'aggiunta.
- Quando video e audio sono già compatibili la conversione è un semplice remux:
  nessuna perdita di qualità e pochi secondi di attesa.
- I sottotitoli testuali vengono conservati; quelli a immagine (PGS/VOBSUB)
  possono essere impressi nel video (opzionale).
- Gli originali non vengono toccati, salvo attivare lo spostamento nel Cestino.

## Struttura

- `app/` — applicazione nativa macOS (SwiftUI + AVKit)
  - `Sources/` — codice sorgente
  - `Tests/` — banco di prova headless
  - `build.sh` — compilazione e installazione
- `mediateca.py` — prima versione basata su server web locale (Python, senza
  dipendenze). Mantenuta come riferimento; l'app nativa è la versione consigliata.

## Percorsi dati

- Libreria e progressi: `~/Library/Application Support/Mediateca/library.json`
- Backup giornalieri: `~/Library/Application Support/Mediateca/backups/`
- Anteprime: `~/Library/Application Support/Mediateca/thumbs/`
