import AppKit
import Foundation

/// Esegue VibraVid come sottoprocesso Python e alimenta la UI con i log,
/// segnalando i file scaricati man mano che compaiono nella cartella
/// di output.
@MainActor
final class VibraVidRunner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
        case done(exit: Int32)
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: String = ""
    @Published private(set) var currentCommand: [String] = []
    @Published private(set) var downloadedFiles: [URL] = []

    /// Destinazione scelta prima di avviare il download: se impostata, i file
    /// che arrivano finiscono lì invece che nella serie dedotta dal path.
    var pendingTarget: DownloadTarget?

    enum DownloadTarget: Equatable {
        case newSeries(title: String, season: Int)
        case newMovie(title: String)
        case appendTo(seriesID: UUID, season: Int)
    }

    /// Domanda che VibraVid sta ponendo in questo momento (nil = nessuna).
    /// Viene ricalcolata a ogni chunk di output; la UI ci si aggancia per
    /// mostrare un pannello di risposta invece del solo testo grezzo.
    @Published private(set) var pendingPrompt: PendingPrompt?

    struct PendingPrompt: Equatable {
        var question: String
        var table: PromptTable?
        /// Insieme di suggerimenti rapidi cliccabili (es. "*", "q", "Invio").
        var quickReplies: [String]
    }

    struct PromptTable: Equatable {
        var headers: [String]
        var rows: [[String]]

        /// Alcune tabelle di VibraVid mettono l'indice in prima colonna
        /// (es. la selezione titoli): serve per il tap-to-send.
        var indexColumn: Int? {
            headers.firstIndex { h in
                let l = h.lowercased()
                return l == "index" || l == "id" || l == "#" || l == "n"
            }
        }
    }

    /// Notifica quando un nuovo file di download compare su disco.
    var onNewFile: ((URL) -> Void)?

    private let bridge: VibraVidBridge
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var snapshot: Set<String> = []

    /// Attesa dopo l'ultimo chunk prima di dichiarare l'output "fermo" e
    /// interpretarlo come prompt: rich stampa il prompt e non manda a capo.
    private static let promptQuietMillis: UInt64 = 350
    private var promptTask: Task<Void, Never>?

    /// Il log completo cresce dentro `logBuffer` e viene ribaltato in `log`
    /// (osservato dalla UI) al massimo `logFlushHz` volte al secondo: senza
    /// questo, l'output di VibraVid a raffica manda in stallo il main thread.
    private var logBuffer: String = ""
    private var flushScheduled = false
    private static let logMaxChars = 60_000
    private static let logFlushMillis: UInt64 = 120

    init(bridge: VibraVidBridge) {
        self.bridge = bridge
    }

    var isRunning: Bool { phase == .running }

    // MARK: - API

    /// Avvia una ricerca su un sito specifico. Tutto il resto (scelta titolo,
    /// stagione, episodi, tracce) viene gestito interattivamente dai prompt
    /// che l'utente vede nel pannello sopra la console.
    func searchAndDownload(query: String, siteName: String, trackPresetKey: String?) {
        var args = ["-s", query, "--site", siteName, "--close-console", "true"]
        if let trackPresetKey, !trackPresetKey.isEmpty {
            args += ["--tracks", trackPresetKey]
        }
        launch(args: args)
    }

    /// Ricerca globale su tutti i siti (categoria opzionale). Anche qui le
    /// scelte successive avvengono via prompt.
    func globalSearch(query: String, category: Int?) {
        var args = ["-s", query, "--global", "--close-console", "true"]
        if let category { args += ["--category", "\(category)"] }
        launch(args: args)
    }

    /// Download diretto da URL (MP4/HLS/DASH/ISM), con eventuali header e
    /// chiavi DRM.
    func directDownload(
        url: String,
        output: String?,
        headers: [String],
        licenseURL: String?,
        licenseHeaders: [String],
        keys: [String],
        drm: String
    ) {
        var args = ["--down", url, "--no-tracks-prompt", "--close-console", "true", "--drm", drm]
        if let output, !output.isEmpty { args += ["-o", output] }
        for h in headers where !h.isEmpty { args += ["--headers", h] }
        if let licenseURL, !licenseURL.isEmpty { args += ["--license-url", licenseURL] }
        for h in licenseHeaders where !h.isEmpty { args += ["--license-headers", h] }
        for k in keys where !k.isEmpty { args += ["--key", k] }
        launch(args: args)
    }

    func cancel() {
        process?.terminate()
        stopWatcher()
        stdinHandle = nil
        promptTask?.cancel()
        pendingPrompt = nil
        phase = .cancelled
    }

    func clearLog() { log = ""; logBuffer = "" }

    /// Invia una riga di testo allo stdin del processo Python. Serve a
    /// rispondere ai prompt interattivi di VibraVid (scelta episodio, scelta
    /// titolo nella ricerca globale, ecc.).
    func send(_ text: String) {
        guard isRunning, let handle = stdinHandle else { return }
        let payload = (text + "\n").data(using: .utf8) ?? Data()
        do {
            try handle.write(contentsOf: payload)
            append("› \(text)\n")
            pendingPrompt = nil     // il prompt corrente è stato risposto
        } catch {
            append("⚠ impossibile inviare input: \(error.localizedDescription)\n")
        }
    }

    // MARK: - Esecuzione

    private func launch(args: [String]) {
        guard !isRunning else {
            append("⚠ Un download è già in corso. Annulla prima di lanciarne un altro.\n")
            return
        }
        guard bridge.isInstalled else {
            phase = .failed("VibraVid non trovato in \(bridge.installDir.path).\n"
                + "Verifica il percorso in Impostazioni.")
            return
        }

        downloadedFiles = []
        pendingPrompt = nil
        snapshot = enumerateCurrentFiles()
        startWatcher()

        let p = Process()
        p.executableURL = bridge.pythonPath
        p.currentDirectoryURL = bridge.installDir
        p.arguments = [bridge.entryPoint.path] + args

        // PYTHONUNBUFFERED forza i log a comparire riga per riga invece di
        // arrivare a blocchi solo alla fine.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["FORCE_COLOR"] = "0"       // rich non stampa sequenze ANSI
        env["NO_COLOR"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // stdin collegato a una pipe: senza questo qualunque Prompt.ask di
        // rich riceverebbe EOF e crasherebbe il processo.
        let inPipe = Pipe()
        p.standardInput = inPipe
        stdinHandle = inPipe.fileHandleForWriting

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let clean = Self.stripANSI(text)
            Task { @MainActor [weak self] in self?.append(clean) }
        }

        currentCommand = ["python", "manual.py"] + args
        append("$ python manual.py \(args.joined(separator: " "))\n\n")

        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            phase = .failed(error.localizedDescription)
            stopWatcher()
            return
        }
        process = p
        phase = .running

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                try? inPipe.fileHandleForWriting.close()
                self.stdinHandle = nil
                self.stopWatcher()
                // Ultima scansione: cattura anche i file scritti dopo l'ultima notifica.
                self.detectNewFiles()
                if self.phase != .cancelled {
                    self.phase = .done(exit: proc.terminationStatus)
                }
                self.process = nil
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
        }
    }

    private func append(_ text: String) {
        logBuffer += text
        // Limita a un tail: la UI mostra solo le ultime righe utili, altrimenti
        // rendere 300k caratteri di Text blocca il main thread.
        if logBuffer.count > Self.logMaxChars {
            logBuffer = String(logBuffer.suffix(Self.logMaxChars))
        }
        scheduleFlush()
        scheduleprompt()
    }

    /// Ribalta il buffer sulla property osservata dalla vista al massimo ogni
    /// `logFlushMillis`. Un flush finale scatta a inizio pausa, così l'ultima
    /// riga non resta indietro.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.logFlushMillis * 1_000_000)
            await MainActor.run {
                guard let self else { return }
                self.flushScheduled = false
                if self.log != self.logBuffer { self.log = self.logBuffer }
            }
        }
    }

    /// Debounce: ogni volta che arriva output nuovo si azzera l'attesa. Se
    /// per `promptQuietMillis` non succede nulla e l'ultima riga sembra un
    /// prompt (finisce con :, ?, > senza andare a capo), lo pubblichiamo.
    private func scheduleprompt() {
        promptTask?.cancel()
        promptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.promptQuietMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.detectPrompt() }
        }
    }

    private func detectPrompt() {
        guard isRunning else { pendingPrompt = nil; return }
        // Analizziamo solo le ultime 8k caratteri: le tabelle e i prompt sono
        // sempre alla fine, e su questo taglio il parser scala anche con log
        // molto lunghi.
        let tail = logBuffer.count > 8_000
            ? String(logBuffer.suffix(8_000))
            : logBuffer
        guard let question = Self.trailingPrompt(in: tail) else {
            pendingPrompt = nil
            return
        }
        let table = Self.parseTable(in: tail)
        let quick = Self.quickReplies(for: question)
        let new = PendingPrompt(question: question, table: table, quickReplies: quick)
        if new != pendingPrompt { pendingPrompt = new }
    }

    // MARK: Detection

    /// L'ultima "riga" del log senza \n finale è un candidato prompt: rich
    /// lo scrive con `input(prompt)` che non chiude la riga.
    nonisolated static func trailingPrompt(in log: String) -> String? {
        guard !log.isEmpty, log.last != "\n" else { return nil }
        let lastLine = log.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Un prompt tipico finisce con : ? > oppure con "]" (choices di rich).
        let endings: Set<Character> = [":", "?", ">", "]"]
        let last = trimmed.last!
        guard endings.contains(last) || trimmed.lowercased().contains("press enter") else {
            return nil
        }
        return trimmed
    }

    nonisolated static func quickReplies(for question: String) -> [String] {
        let q = question.lowercased()
        var replies: [String] = []
        if q.contains("* to download all") || q.contains("* to")   { replies += ["*"] }
        if q.contains("press enter")                                { replies += ["Invio"] }
        if q.contains("'q'") || q.contains("q to quit")             { replies += ["q"] }
        return replies
    }

    /// Cerca l'ultima tabella "box" nel log e la trasforma in righe/colonne.
    /// Tollera i due stili di riquadro usati da rich (linee sottili `│` e
    /// grosse `┃`) e i separatori a doppia linea.
    nonisolated static func parseTable(in log: String) -> PromptTable? {
        // Lavoriamo sulle ultime ~40 righe per non scansionare l'intero log.
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(80).map(String.init)
        // Individua l'ultima riga di chiusura tabella.
        let bottomChars: Set<Character> = ["└", "╰", "┗", "╚"]
        guard let bottomIdx = lines.lastIndex(where: { line in
            line.contains(where: { bottomChars.contains($0) })
        }) else { return nil }
        // ...e la relativa apertura, appena sopra.
        let topChars: Set<Character> = ["┌", "╭", "┏", "╔"]
        guard let topIdx = lines[..<bottomIdx].lastIndex(where: { line in
            line.contains(where: { topChars.contains($0) })
        }) else { return nil }

        let separators: Set<Character> = ["│", "┃"]
        var rawRows: [[String]] = []
        for i in (topIdx + 1)..<bottomIdx {
            let line = lines[i]
            guard line.contains(where: { separators.contains($0) }) else { continue }
            // Se la riga è tutta caratteri di separazione orizzontali la saltiamo.
            let onlyBox = line.allSatisfy { c in
                c.isWhitespace || "─━═┃│├┤┣┫╞╡╪┼┿╫╪".contains(c) || topChars.contains(c) || bottomChars.contains(c)
            }
            if onlyBox { continue }
            let cells = line.split(whereSeparator: { separators.contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !cells.isEmpty { rawRows.append(cells) }
        }
        guard rawRows.count >= 2 else { return nil }
        // La prima riga è l'header.
        let headers = rawRows[0]
        let width = headers.count
        let body = rawRows.dropFirst().filter { $0.count == width }
        guard !body.isEmpty else { return nil }
        return PromptTable(headers: headers, rows: Array(body))
    }

    /// Rimuove i codici ANSI residui che rich stampa in alcuni contesti anche
    /// con NO_COLOR (es. sequenze di posizionamento cursore).
    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\[[0-9;?]*[a-zA-Z]"#, with: "",
                               options: .regularExpression)
    }

    // MARK: - Rilevamento file scaricati

    private func enumerateCurrentFiles() -> Set<String> {
        var out: Set<String> = []
        let root = bridge.downloadRoot
        guard let en = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en where VideoTypes.isVideo(url) {
            out.insert(url.path)
        }
        return out
    }

    private func startWatcher() {
        stopWatcher()
        let root = bridge.downloadRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        watchedFD = open(root.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .extend, .rename],
            queue: .main)
        src.setEventHandler { [weak self] in self?.detectNewFiles() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.watchedFD >= 0 { close(self.watchedFD); self.watchedFD = -1 }
        }
        src.resume()
        watcher = src
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    /// Confronta lo stato attuale della cartella con lo snapshot iniziale:
    /// tutto ciò che non c'era prima e supera i 200 KB è un nuovo download.
    private func detectNewFiles() {
        let current = enumerateCurrentFiles()
        let fresh = current.subtracting(snapshot)
        guard !fresh.isEmpty else { return }
        for path in fresh {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            // Cartelle temporanee di ffmpeg producono a volte spezzoni piccoli:
            // il taglio scarta i frammenti e considera solo file completi.
            guard size > 200_000 else { continue }
            let url = URL(fileURLWithPath: path)
            snapshot.insert(path)
            if !downloadedFiles.contains(url) {
                downloadedFiles.append(url)
                onNewFile?(url)
                append("\n📥 nuovo file: \(url.lastPathComponent)\n")
            }
        }
    }
}
