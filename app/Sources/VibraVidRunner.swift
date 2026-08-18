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

    /// Notifica quando un nuovo file di download compare su disco.
    var onNewFile: ((URL) -> Void)?

    private let bridge: VibraVidBridge
    private var process: Process?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var snapshot: Set<String> = []

    init(bridge: VibraVidBridge) {
        self.bridge = bridge
    }

    var isRunning: Bool { phase == .running }

    // MARK: - API

    /// Ricerca su un provider specifico con selezione automatica del primo
    /// risultato. Se `season` o `episode` sono valorizzati vengono passati
    /// a VibraVid, altrimenti si affida ai valori del config.
    func searchAndDownload(
        query: String,
        siteName: String,
        season: String?,
        episode: String?,
        trackPresetKey: String?
    ) {
        var args = ["-s", query, "--site", siteName, "--auto-first",
                    "--no-tracks-prompt", "--close-console", "true"]
        if let season, !season.isEmpty { args += ["--season", season] }
        if let episode, !episode.isEmpty { args += ["--episode", episode] }
        if let trackPresetKey, !trackPresetKey.isEmpty { args += ["--tracks", trackPresetKey] }
        launch(args: args)
    }

    /// Ricerca globale su tutti i siti (categoria opzionale).
    /// Nota: la CLI resta interattiva per la selezione del titolo, quindi
    /// serve solo per aprire il flusso, non per download automatici.
    func globalSearch(query: String, category: Int?) {
        var args = ["-s", query, "--global"]
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
        phase = .cancelled
    }

    func clearLog() { log = "" }

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
        log += text
        // Evita che il log cresca all'infinito nelle sessioni lunghe.
        if log.count > 240_000 {
            log = String(log.suffix(160_000))
        }
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
