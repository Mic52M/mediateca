import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Modello dati

struct Episode: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var path: String
    var title: String
    var number: Int
    var duration: Double = 0
    var position: Double = 0
    var finished: Bool = false
    var lastWatched: Date?
    /// Percorso del file originale, se questo episodio è stato convertito.
    var originalPath: String?

    /// Formati che AVFoundation riproduce nativamente.
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "mp3"]

    var url: URL { URL(fileURLWithPath: path) }
    var needsConversion: Bool {
        !Episode.playableExtensions.contains(url.pathExtension.lowercased())
    }
    var missing: Bool { !FileManager.default.fileExists(atPath: path) }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    /// Iniziato ma non finito: serve per la riga "Continua a guardare".
    var started: Bool { !finished && (position > 20 || (duration > 0 && progress > 0.03)) }
    var remaining: Double { max(0, duration - position) }
}

struct Season: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var number: Int
    var name: String = ""
    var episodes: [Episode] = []

    var label: String { name.isEmpty ? "Stagione \(number)" : name }
}

struct Series: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var seasons: [Season] = []
    var added: Date = Date()

    var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    var firstEpisode: Episode? { seasons.first(where: { !$0.episodes.isEmpty })?.episodes.first }
}

struct LibraryData: Codable {
    var series: [Series] = []
    /// Video aperti dal Finder e non ancora assegnati a una serie.
    var loose: [Episode] = []
}

/// Un episodio con il contesto della serie a cui appartiene.
struct EpisodeRef: Identifiable, Hashable {
    var episode: Episode
    var seriesID: UUID?
    var seriesTitle: String
    var seasonLabel: String
    var seasonNumber: Int

    var id: UUID { episode.id }
    var subtitle: String {
        seriesID == nil ? "Video singolo" : "\(seriesTitle) · S\(seasonNumber)E\(episode.number)"
    }
}

// MARK: - Tipi di file video

enum VideoTypes {
    static let extensions = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpg", "mpeg",
                             "ts", "m2ts", "wmv", "flv", "ogv", "divx", "rmvb", "3gp"]

    /// Tipi accettati dal pannello di apertura. macOS non classifica l'mkv sotto
    /// `public.movie`, quindi filtrando solo per quello i file risulterebbero
    /// disabilitati: qui si aggiunge un tipo per ogni estensione conosciuta.
    static var contentTypes: [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        for t in [UTType.audiovisualContent, .movie, .video] where seen.insert(t.identifier).inserted {
            types.append(t)
        }
        for ext in extensions {
            if let t = UTType(filenameExtension: ext), seen.insert(t.identifier).inserted {
                types.append(t)
            }
        }
        return types
    }

    static func isVideo(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Espande le cartelle nei video contenuti; i file singoli passano se sono video.
    static func collect(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: u, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                out += items.filter(isVideo)
            } else if isVideo(u) {
                out.append(u)
            }
        }
        return out
    }
}

// MARK: - Percorsi su disco

enum Paths {
    static let dir: URL = {
        // MEDIATECA_HOME isola i dati: test e build di verifica non devono mai
        // poter scrivere sulla libreria vera.
        let d: URL
        if let override = ProcessInfo.processInfo.environment["MEDIATECA_HOME"], !override.isEmpty {
            d = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            d = base.appendingPathComponent("Mediateca", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let library = dir.appendingPathComponent("library.json")

    static let backups: URL = {
        let d = dir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let thumbs: URL = {
        let d = dir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func thumb(_ id: UUID) -> URL {
        thumbs.appendingPathComponent("\(id.uuidString).jpg")
    }
}

/// Tiene le anteprime in memoria: senza cache ogni ridisegno rileggerebbe i JPEG
/// dal disco, ed è quello che faceva sfarfallare la libreria.
@MainActor
enum ThumbCache {
    private static var images: [UUID: NSImage] = [:]
    private static var absent: Set<UUID> = []

    static func image(for id: UUID) -> NSImage? {
        if let cached = images[id] { return cached }
        if absent.contains(id) { return nil }
        if let img = NSImage(contentsOf: Paths.thumb(id)) {
            images[id] = img
            return img
        }
        absent.insert(id)
        return nil
    }

    static func invalidate(_ id: UUID) {
        images.removeValue(forKey: id)
        absent.remove(id)
    }
}

// MARK: - Lettura media

enum Media {
    static func duration(of url: URL) async -> Double {
        // Per i contenitori che AVFoundation non gestisce (mkv, avi…) si va
        // direttamente a ffprobe: interrogare AVFoundation su un mkv non
        // fallisce, resta appeso.
        guard Episode.playableExtensions.contains(url.pathExtension.lowercased()) else {
            return await ffprobeDuration(of: url)
        }
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite && s > 0 { return s }
        }
        return await ffprobeDuration(of: url)
    }

    static func ffprobeDuration(of url: URL) async -> Double {
        guard let ffprobe = await Converter.ffprobe else { return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries", "format=duration",
                       "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(text ?? "") ?? 0
    }

    /// Genera l'anteprima se non esiste già in cache. Restituisce true se il file è pronto.
    @discardableResult
    static func makeThumbnail(for episode: Episode, duration: Double) async -> Bool {
        let dest = Paths.thumb(episode.id)
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard !episode.missing else { return false }

        let asset = AVURLAsset(url: episode.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let seconds = duration > 0 ? max(1, duration * 0.12) : 5
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else { return false }

        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return false }
        try? data.write(to: dest)
        return true
    }
}

// MARK: - Parsing dei nomi file

enum NameParser {
    /// Estrae stagione ed episodio da nomi tipo "Anime S01E04", "Ep 04", "Serie - 04".
    static func parse(_ url: URL) -> (season: Int?, episode: Int?, title: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        var season: Int?
        var episode: Int?

        if let m = stem.range(of: #"[Ss](\d{1,2})[ ._\-]?[EeXx](\d{1,3})"#, options: .regularExpression) {
            let nums = stem[m].compactMap { $0.isNumber ? $0 : nil }
            _ = nums
            let digits = stem[m].split(whereSeparator: { !$0.isNumber }).map(String.init)
            if digits.count >= 2 { season = Int(digits[0]); episode = Int(digits[1]) }
        }
        if episode == nil,
           let m = stem.range(of: #"(?i)\b(?:e|ep|episodio|episode)[ ._\-]?(\d{1,3})\b"#, options: .regularExpression) {
            episode = Int(stem[m].split(whereSeparator: { !$0.isNumber }).map(String.init).last ?? "")
        }
        if episode == nil,
           let m = stem.range(of: #"(\d{1,3})\s*$"#, options: .regularExpression) {
            episode = Int(stem[m].trimmingCharacters(in: .whitespaces))
        }

        var title = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = stem }
        return (season, episode, title)
    }

    /// Suggerisce il titolo della serie: cartella contenitore, o prefisso comune dei file.
    static func suggestSeriesTitle(for urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let folders = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        if folders.count == 1, let f = folders.first,
           !["Movies", "Downloads", "Desktop", "Documents", "Video", "Movie"].contains(f) {
            return f.replacingOccurrences(of: "_", with: " ")
        }
        guard urls.count > 1 else {
            return parse(first).title
        }
        let stems = urls.map { $0.deletingPathExtension().lastPathComponent }
        var prefix = stems[0]
        for s in stems.dropFirst() {
            prefix = String(zip(prefix, s).prefix { $0 == $1 }.map(\.0))
        }
        let cleaned = prefix
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.–—0123456789eEpP"))
        return cleaned.count >= 2 ? cleaned : parse(first).title
    }

    /// Ordinamento "naturale": Ep2 prima di Ep10.
    static func naturalSort(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
