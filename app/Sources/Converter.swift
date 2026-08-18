import AppKit
import Foundation

/// Converte in .mp4 i file che AVFoundation non sa riprodurre (mkv, avi, webm…).
/// Quando video e audio sono già compatibili fa un semplice remux: nessuna
/// ricodifica, qualità identica all'originale e pochi secondi di attesa.
@MainActor
final class Converter: ObservableObject {

    enum State: Equatable {
        case waiting
        case running(Double)      // 0…1
        case done
        case failed(String)
    }

    struct Job: Identifiable {
        let id: UUID              // = id dell'episodio
        var title: String
        var source: URL
        var duration: Double
        var state: State = .waiting
        var remuxOnly = true
        var burnedIn = false
    }

    @Published private(set) var jobs: [Job] = []
    @Published var trashOriginals = false
    /// I sottotitoli a immagine non entrano in un mp4: se attivo vengono
    /// impressi nel video (richiede ricodifica) invece di essere persi.
    @Published var burnImageSubtitles = true
    @Published var lastError: String?
    /// Avvisi non bloccanti da mostrare a fine conversione.
    @Published var notice: String?

    /// Invocata sul main actor quando un file è pronto: (episodeID, nuovo URL).
    var onConverted: ((UUID, URL) -> Void)?

    private var process: Process?
    private var isRunning = false

    var activeJobs: [Job] { jobs.filter { $0.state != .done } }
    var isBusy: Bool { jobs.contains { if case .done = $0.state { return false }; return true } }

    func state(for episodeID: UUID) -> State? {
        jobs.first { $0.id == episodeID }?.state
    }

    // MARK: - Individuazione di ffmpeg

    static var ffmpeg: String? { tool("ffmpeg") }
    static var ffprobe: String? { tool("ffprobe") }

    static func tool(_ name: String) -> String? {
        if let custom = UserDefaults.standard.string(forKey: "ffmpegDir") {
            let p = (custom as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var isAvailable: Bool { ffmpeg != nil && ffprobe != nil }

    // MARK: - Coda

    func enqueue(episodeID: UUID, title: String, source: URL, duration: Double) {
        guard !jobs.contains(where: { $0.id == episodeID }) else { return }
        guard Converter.isAvailable else {
            lastError = "ffmpeg non trovato. Installalo con “brew install ffmpeg”, "
                      + "poi riprova la conversione."
            return
        }
        jobs.append(Job(id: episodeID, title: title, source: source, duration: duration))
        startNextIfIdle()
    }

    func cancelAll() {
        process?.terminate()
        process = nil
        isRunning = false
        jobs.removeAll { $0.state != .done }
    }

    func clearFinished() {
        jobs.removeAll { if case .done = $0.state { return true }; return false }
    }

    private func startNextIfIdle() {
        guard !isRunning,
              let idx = jobs.firstIndex(where: { $0.state == .waiting })
        else { return }
        isRunning = true
        Task { await run(jobIndex: idx) }
    }

    // MARK: - Esecuzione

    private func run(jobIndex: Int) async {
        guard jobIndex < jobs.count else { isRunning = false; return }
        let job = jobs[jobIndex]
        let id = job.id

        var duration = job.duration
        if duration <= 0 { duration = await Media.duration(of: job.source) }

        let info = await probeStreams(job.source)
        let dest = outputURL(for: job.source)
        let plan = buildArguments(source: job.source, dest: dest, info: info)

        setState(id, .running(0))
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].remuxOnly = plan.remuxOnly
            jobs[i].burnedIn = plan.burnedIn
        }

        var result = await execute(plan.args, duration: duration, id: id)

        // Se i sottotitoli fanno comunque fallire il muxing, si ritenta senza:
        // meglio un file riproducibile che nessun file, ma va detto.
        if !result.ok, plan.hasSubtitles {
            let retry = buildArguments(source: job.source, dest: dest, info: info, dropSubtitles: true)
            setState(id, .running(0))
            result = await execute(retry.args, duration: duration, id: id)
            if result.ok {
                notice = "“\(job.title)”: i sottotitoli non erano compatibili con il "
                       + "formato mp4 e sono stati esclusi. L'originale li conserva."
            }
        }

        if result.ok, FileManager.default.fileExists(atPath: dest.path) {
            setState(id, .done)
            onConverted?(id, dest)
            if trashOriginals {
                try? FileManager.default.trashItem(at: job.source, resultingItemURL: nil)
            }
        } else {
            try? FileManager.default.removeItem(at: dest)
            setState(id, .failed(result.message))
            lastError = "Conversione di “\(job.title)” non riuscita.\n\(result.message)"
        }

        isRunning = false
        startNextIfIdle()
    }

    private func setState(_ id: UUID, _ s: State) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = s }
    }

    private func execute(_ args: [String], duration: Double, id: UUID) async -> (ok: Bool, message: String) {
        guard let ffmpeg = Converter.ffmpeg else { return (false, "ffmpeg non trovato") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        process = p

        let tail = TailBuffer()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            tail.append(text)
            guard duration > 0, let secs = Converter.parseTime(text) else { return }
            let fraction = min(0.999, secs / duration)
            Task { @MainActor [weak self] in self?.setState(id, .running(fraction)) }
        }

        // terminationHandler va installato PRIMA di run(): un remux di pochi
        // secondi può terminare prima, e la continuation resterebbe appesa.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in cont.resume() }
                do {
                    try p.run()
                } catch {
                    p.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            return (false, error.localizedDescription)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        process = nil

        let ok = p.terminationStatus == 0
        return (ok, ok ? "" : tail.lastLines(6))
    }

    /// Estrae l'ultimo `time=00:01:23.45` dal flusso di avanzamento di ffmpeg.
    nonisolated static func parseTime(_ text: String) -> Double? {
        var result: Double?
        var search = text[...]
        while let r = search.range(of: #"time=(\d+):(\d{2}):(\d{2})\.(\d{2})"#,
                                   options: .regularExpression) {
            let parts = search[r].dropFirst(5).split(separator: ":")
            if parts.count == 3 {
                let sec = parts[2].split(separator: ".")
                let h = Double(parts[0]) ?? 0
                let m = Double(parts[1]) ?? 0
                let s = Double(sec.first ?? "0") ?? 0
                let cs = Double(sec.count > 1 ? sec[1] : "0") ?? 0
                result = h * 3600 + m * 60 + s + cs / 100
            }
            search = search[r.upperBound...]
        }
        return result
    }

    // MARK: - Analisi e strategia

    struct SubtitleStream {
        var index: Int          // indice assoluto nel file
        var order: Int          // posizione fra i soli sottotitoli
        var codec: String
        var language: String?

        /// I sottotitoli testuali entrano in un mp4 come mov_text; quelli a
        /// immagine (PGS dei Blu-ray, VOBSUB dei DVD) no: vanno impressi.
        var isText: Bool {
            ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text", "eia_608", "subviewer"]
                .contains(codec)
        }
    }

    struct StreamInfo {
        var video = ""
        var audio: [String] = []
        var subtitles: [SubtitleStream] = []
    }

    private func probeStreams(_ url: URL) async -> StreamInfo {
        guard let ffprobe = Converter.ffprobe else { return StreamInfo() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        var args = ["-v", "error"]
        if url.pathExtension.lowercased() == "ts" {
            args += ["-f", "mpegts"]
        }
        args += ["-show_entries",
                 "stream=index,codec_type,codec_name:stream_tags=language",
                 "-of", "json", url.path]
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return StreamInfo() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var info = StreamInfo()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else { return info }
        var subOrder = 0
        for s in streams {
            let name = (s["codec_name"] as? String ?? "").lowercased()
            switch s["codec_type"] as? String {
            case "video" where info.video.isEmpty: info.video = name
            case "audio": info.audio.append(name)
            case "subtitle":
                let tags = s["tags"] as? [String: Any]
                info.subtitles.append(SubtitleStream(
                    index: s["index"] as? Int ?? 0,
                    order: subOrder,
                    codec: name,
                    language: tags?["language"] as? String))
                subOrder += 1
            default: break
            }
        }
        return info
    }

    private func buildArguments(source: URL, dest: URL, info: StreamInfo,
                                dropSubtitles: Bool = false)
        -> (args: [String], remuxOnly: Bool, hasSubtitles: Bool, burnedIn: Bool) {

        let textSubs = dropSubtitles ? [] : info.subtitles.filter(\.isText)
        let imageSubs = dropSubtitles ? [] : info.subtitles.filter { !$0.isText }
        let videoIsCompatible = ["h264", "hevc", "h265", "mpeg4"].contains(info.video)

        // Alcuni .ts scaricati da HLS (VibraVid & simili) non iniziano con
        // il byte di sync 0x47, quindi ffmpeg non li riconosce da solo:
        // forzare il demuxer risolve senza toccare il payload.
        var args: [String] = ["-y", "-hide_banner"]
        if source.pathExtension.lowercased() == "ts" {
            args += ["-fflags", "+genpts+discardcorrupt", "-f", "mpegts"]
        }
        args += ["-i", source.path]
        var remux = true
        var burnedIn = false

        // Sottotitoli solo a immagine: l'mp4 non li può contenere, quindi
        // l'unico modo per non perderli è imprimerli nel video.
        if textSubs.isEmpty, let bitmap = imageSubs.first, burnImageSubtitles {
            args += ["-filter_complex", "[0:v:0][0:s:\(bitmap.order)]overlay[vout]",
                     "-map", "[vout]", "-map", "0:a?"]
            args += ["-c:v", "hevc_videotoolbox", "-q:v", "62", "-tag:v", "hvc1"]
            burnedIn = true
            remux = false
        } else {
            args += ["-map", "0:v:0", "-map", "0:a?"]
            // Si mappano SOLO i sottotitoli testuali, uno per uno: un "-map 0:s?"
            // trascinerebbe dentro anche quelli a immagine, facendo fallire il
            // muxing e perdendo così tutte le tracce.
            for sub in textSubs { args += ["-map", "0:\(sub.index)"] }

            if videoIsCompatible {
                args += ["-c:v", "copy"]
            } else {
                args += ["-c:v", "hevc_videotoolbox", "-q:v", "60", "-tag:v", "hvc1"]
                remux = false
            }
        }

        if info.audio.allSatisfy({ ["aac", "mp3"].contains($0) }) && !info.audio.isEmpty {
            args += ["-c:a", "copy"]
        } else {
            args += ["-c:a", "aac", "-b:a", "256k"]
        }

        if !textSubs.isEmpty {
            args += ["-c:s", "mov_text"]
            // Lingua di ogni traccia, e prima traccia marcata come predefinita:
            // così i lettori la propongono da soli.
            for (i, sub) in textSubs.enumerated() {
                if let lang = sub.language, !lang.isEmpty {
                    args += ["-metadata:s:s:\(i)", "language=\(lang)"]
                }
            }
            args += ["-disposition:s:0", "default"]
        }

        args += ["-movflags", "+faststart", dest.path]
        // `hasSubtitles` indica che il piano coinvolge sottotitoli in qualunque
        // forma: serve a sapere se vale la pena ritentare senza, e l'impressione
        // è proprio il caso che più facilmente può fallire.
        return (args, remux, !textSubs.isEmpty || burnedIn, burnedIn)
    }

    private func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem).mp4")

        // Non sovrascrivere mai un file esistente.
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) (\(n)).mp4")
            n += 1
        }
        // Se la cartella non è scrivibile, ripiega su ~/Movies/Mediateca.
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            let fallback = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Movies/Mediateca", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback.appendingPathComponent(candidate.lastPathComponent)
        }
        return candidate
    }
}

/// Accumula solo la coda dell'output di ffmpeg, per i messaggi d'errore.
private final class TailBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
        if text.count > 8000 { text = String(text.suffix(4000)) }
    }

    func lastLines(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return text.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}
