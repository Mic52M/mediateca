import AVFoundation
import AVKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    @Published var data = LibraryData()
    @Published var selection: SidebarItem? = .home
    @Published var importer: ImportDraft?
    @Published var nowPlaying: EpisodeRef?
    @Published var player: AVPlayer?
    /// Episodi la cui anteprima è pronta. Sostituisce un contatore globale: così
    /// solo la card interessata si ridisegna, invece dell'intera libreria.
    @Published var thumbReady: Set<UUID> = []
    @Published var alert: String?
    /// Serie/film per cui è stata richiesta la rimozione dalla libreria: la
    /// UI mostra un alert di conferma prima di eseguire davvero deleteSeries.
    @Published var pendingRemoval: PendingRemoval?

    struct PendingRemoval: Identifiable, Equatable {
        var id: UUID
        var title: String
        var isMovie: Bool
    }

    func requestRemoveSeries(_ id: UUID) {
        guard let s = data.series.first(where: { $0.id == id }) else { return }
        pendingRemoval = PendingRemoval(id: id, title: s.title, isMovie: s.isMovie)
    }

    func confirmPendingRemoval() {
        guard let p = pendingRemoval else { return }
        pendingRemoval = nil
        deleteSeries(p.id)
    }

    func cancelPendingRemoval() { pendingRemoval = nil }
    /// Visibilità della barra sopra il video. Vive qui e non nella vista perché
    /// anche la finestra (semaforo, titolo) deve seguirla da un'unica sorgente.
    @Published var chromeVisible = true

    /// Accende da sola la traccia di sottotitoli quando il file ne ha una.
    @Published var autoSubtitles = UserDefaults.standard.object(forKey: "autoSubtitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSubtitles, forKey: "autoSubtitles") }
    }

    let converter = Converter()
    let vibravid = VibraVidBridge()
    lazy var runner: VibraVidRunner = {
        let r = VibraVidRunner(bridge: vibravid)
        r.onNewFile = { [weak self, weak r] url in
            self?.absorbDownloaded(url, target: r?.pendingTarget)
        }
        return r
    }()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var savedTick = 0

    enum SidebarItem: Hashable {
        case home
        case download
        case settings
        case series(UUID)
    }

    init() {
        load()
        converter.onConverted = { [weak self] episodeID, newURL in
            guard let self else { return }
            self.update(episodeID) {
                if $0.originalPath == nil { $0.originalPath = $0.path }
                $0.path = newURL.path
            }
            try? FileManager.default.removeItem(at: Paths.thumb(episodeID))
            ThumbCache.invalidate(episodeID)
            self.thumbReady.remove(episodeID)
            Task { await self.refreshMetadata() }
        }
    }

    // MARK: - Conversione

    /// Mette in coda tutti i file non riproducibili (mkv, avi, webm…).
    func convertPending() {
        for ep in allEpisodes where ep.needsConversion && !ep.missing {
            converter.enqueue(episodeID: ep.id, title: ep.title,
                              source: ep.url, duration: ep.duration)
        }
    }

    func convert(_ ep: Episode) {
        guard !ep.missing else { return }
        converter.enqueue(episodeID: ep.id, title: ep.title,
                          source: ep.url, duration: ep.duration)
    }

    // MARK: - Persistenza

    func load() {
        guard let raw = try? Data(contentsOf: Paths.library),
              let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw)
        else { return }
        data = decoded
        snapshotBackup(raw)
        Task { await refreshMetadata() }
    }

    /// Copia giornaliera della libreria all'avvio, ultime 7 conservate: se il
    /// file si corrompe o viene sovrascritto, la struttura è recuperabile.
    private func snapshotBackup(_ raw: Data) {
        guard !data.series.isEmpty || !data.loose.isEmpty else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dest = Paths.backups.appendingPathComponent("library-\(fmt.string(from: Date())).json")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? raw.write(to: dest, options: .atomic)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: Paths.backups, includingPropertiesForKeys: nil)) ?? []
        for old in existing.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(7) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let raw = try? encoder.encode(data) {
            try? raw.write(to: Paths.library, options: .atomic)
        }
    }

    // MARK: - Accesso agli episodi

    func series(_ id: UUID) -> Series? { data.series.first { $0.id == id } }

    func ref(for episode: Episode) -> EpisodeRef {
        for s in data.series {
            for season in s.seasons where season.episodes.contains(where: { $0.id == episode.id }) {
                return EpisodeRef(episode: episode, seriesID: s.id, seriesTitle: s.title,
                                  seasonLabel: season.label, seasonNumber: season.number)
            }
        }
        return EpisodeRef(episode: episode, seriesID: nil, seriesTitle: episode.title,
                          seasonLabel: "", seasonNumber: 0)
    }

    func update(_ id: UUID, _ body: (inout Episode) -> Void) {
        for i in data.series.indices {
            for j in data.series[i].seasons.indices {
                if let k = data.series[i].seasons[j].episodes.firstIndex(where: { $0.id == id }) {
                    body(&data.series[i].seasons[j].episodes[k])
                    save()
                    return
                }
            }
        }
        if let k = data.loose.firstIndex(where: { $0.id == id }) {
            body(&data.loose[k])
            save()
        }
    }

    func episode(_ id: UUID) -> Episode? {
        for s in data.series {
            for season in s.seasons {
                if let e = season.episodes.first(where: { $0.id == id }) { return e }
            }
        }
        return data.loose.first { $0.id == id }
    }

    var allEpisodes: [Episode] {
        data.series.flatMap { $0.seasons.flatMap(\.episodes) } + data.loose
    }

    /// Serie tv in libreria (esclude i film).
    var tvSeries: [Series] { data.series.filter { !$0.isMovie } }

    /// Film in libreria.
    var movies: [Series] { data.series.filter { $0.isMovie } }

    /// Titolo da mettere nell'hero banner della home: preferisce l'ultimo
    /// episodio iniziato e non finito; se non c'è, il più recente in libreria.
    var featured: EpisodeRef? {
        if let ep = continueWatching.first { return ep }
        // Fallback: il file più recente per data di modifica sul disco.
        let candidates = allEpisodes.filter { !$0.missing }
        let sorted = candidates.sorted {
            (fileDate($0) ?? .distantPast) > (fileDate($1) ?? .distantPast)
        }
        if let ep = sorted.first { return ref(for: ep) }
        return nil
    }

    private func fileDate(_ ep: Episode) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ep.path)[.modificationDate] as? Date)
    }

    var continueWatching: [EpisodeRef] {
        allEpisodes
            .filter(\.started)
            .sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
            .prefix(12)
            .map { ref(for: $0) }
    }

    /// Episodio successivo nella stessa stagione, altrimenti il primo della stagione dopo.
    func nextEpisode(after r: EpisodeRef) -> EpisodeRef? {
        guard let sid = r.seriesID, let s = series(sid),
              let sIdx = s.seasons.firstIndex(where: { $0.number == r.seasonNumber }),
              let eIdx = s.seasons[sIdx].episodes.firstIndex(where: { $0.id == r.episode.id })
        else { return nil }
        if eIdx + 1 < s.seasons[sIdx].episodes.count {
            return ref(for: s.seasons[sIdx].episodes[eIdx + 1])
        }
        if sIdx + 1 < s.seasons.count, let first = s.seasons[sIdx + 1].episodes.first {
            return ref(for: first)
        }
        return nil
    }

    /// Toglie un episodio dalla riga "Continua a guardare" senza segnarlo come
    /// visto: azzera solo posizione e ultima visione. L'episodio resta nella
    /// serie come "da iniziare".
    func dismissFromContinueWatching(_ id: UUID) {
        update(id) {
            $0.position = 0
            $0.lastWatched = nil
        }
    }

    // MARK: - Ordinamento e stagioni

    /// Posizione di un episodio: (indice serie, indice stagione, indice episodio).
    private func locate(_ id: UUID) -> (s: Int, season: Int, ep: Int)? {
        for i in data.series.indices {
            for j in data.series[i].seasons.indices {
                if let k = data.series[i].seasons[j].episodes.firstIndex(where: { $0.id == id }) {
                    return (i, j, k)
                }
            }
        }
        return nil
    }

    func position(of id: UUID) -> (index: Int, count: Int)? {
        guard let p = locate(id) else { return nil }
        return (p.ep, data.series[p.s].seasons[p.season].episodes.count)
    }

    /// Sposta di una posizione: -1 su, +1 giù.
    func moveEpisode(_ id: UUID, by offset: Int) {
        guard let p = locate(id) else { return }
        let target = p.ep + offset
        guard data.series[p.s].seasons[p.season].episodes.indices.contains(target) else { return }
        data.series[p.s].seasons[p.season].episodes.swapAt(p.ep, target)
        save()
    }

    /// Trascinamento: porta l'episodio alla posizione della riga di destinazione.
    func moveEpisode(_ id: UUID, toIndex target: Int) {
        guard let p = locate(id), p.ep != target else { return }
        var eps = data.series[p.s].seasons[p.season].episodes
        guard eps.indices.contains(target) else { return }
        let ep = eps.remove(at: p.ep)
        eps.insert(ep, at: min(target, eps.count))
        data.series[p.s].seasons[p.season].episodes = eps
        save()
    }

    /// Sposta un episodio in un'altra stagione, creandola se non esiste.
    func moveEpisode(_ id: UUID, toSeason number: Int) {
        guard let p = locate(id), data.series[p.s].seasons[p.season].number != number else { return }
        let ep = data.series[p.s].seasons[p.season].episodes.remove(at: p.ep)
        if let dest = data.series[p.s].seasons.firstIndex(where: { $0.number == number }) {
            data.series[p.s].seasons[dest].episodes.append(ep)
        } else {
            data.series[p.s].seasons.append(Season(number: number, episodes: [ep]))
        }
        data.series[p.s].seasons.removeAll { $0.episodes.isEmpty }
        data.series[p.s].seasons.sort { $0.number < $1.number }
        save()
    }

    private func withSeason(_ seriesID: UUID, _ seasonNumber: Int,
                            _ body: (inout Season) -> Void) {
        guard let i = data.series.firstIndex(where: { $0.id == seriesID }),
              let j = data.series[i].seasons.firstIndex(where: { $0.number == seasonNumber })
        else { return }
        body(&data.series[i].seasons[j])
        save()
    }

    func sortSeasonByNumber(_ seriesID: UUID, _ seasonNumber: Int) {
        withSeason(seriesID, seasonNumber) { $0.episodes.sort { $0.number < $1.number } }
    }

    func reverseSeason(_ seriesID: UUID, _ seasonNumber: Int) {
        withSeason(seriesID, seasonNumber) { $0.episodes.reverse() }
    }

    /// Rinumera 1…N seguendo l'ordine attuale della lista.
    func renumberSeasonInOrder(_ seriesID: UUID, _ seasonNumber: Int) {
        withSeason(seriesID, seasonNumber) { season in
            for i in season.episodes.indices { season.episodes[i].number = i + 1 }
        }
    }

    func nextSeasonNumber(for seriesID: UUID) -> Int {
        (series(seriesID)?.seasons.map(\.number).max() ?? 0) + 1
    }

    // MARK: - Import

    func beginImport(into seriesID: UUID? = nil, season: Int? = nil, urls: [URL] = []) {
        var draft = ImportDraft(targetSeriesID: seriesID)
        if let sid = seriesID, let s = series(sid) {
            draft.title = s.title
            draft.season = season ?? (s.seasons.map(\.number).max() ?? 1)
        }
        if !urls.isEmpty { draft.add(urls) }
        importer = draft
    }

    func commitImport(_ draft: ImportDraft) {
        guard !draft.items.isEmpty else { importer = nil; return }
        let episodes = draft.items.enumerated().map { idx, item in
            Episode(path: item.url.path,
                    title: item.title.isEmpty ? "Episodio \(idx + 1)" : item.title,
                    number: item.number)
        }

        if let sid = draft.targetSeriesID, let sIdx = data.series.firstIndex(where: { $0.id == sid }) {
            if let seasonIdx = data.series[sIdx].seasons.firstIndex(where: { $0.number == draft.season }) {
                // Si accodano nell'ordine mostrato nel pannello: un riordino
                // automatico qui scombinerebbe una sequenza sistemata a mano.
                data.series[sIdx].seasons[seasonIdx].episodes.append(contentsOf: episodes)
            } else {
                data.series[sIdx].seasons.append(Season(number: draft.season,
                                                        name: draft.seasonName,
                                                        episodes: episodes))
                data.series[sIdx].seasons.sort { $0.number < $1.number }
            }
            selection = .series(sid)
        } else {
            let season = Season(number: draft.season, name: draft.seasonName, episodes: episodes)
            let s = Series(title: draft.title.isEmpty ? "Senza titolo" : draft.title,
                           seasons: [season],
                           kind: draft.isMovie ? .movie : .series)
            data.series.append(s)
            selection = .series(s.id)
        }
        save()
        importer = nil
        convertPending()
        Task { await refreshMetadata() }
    }

    func deleteSeries(_ id: UUID) {
        data.series.removeAll { $0.id == id }
        if case .series(let sel) = selection, sel == id { selection = .home }
        save()
    }

    /// Cambia il tipo di una voce fra film e serie tv. Serve per aggiustare
    /// import fatti prima che esistesse la distinzione.
    func toggleKind(_ id: UUID) {
        guard let i = data.series.firstIndex(where: { $0.id == id }) else { return }
        if data.series[i].isMovie {
            data.series[i].kind = .series
        } else {
            data.series[i].kind = .movie
            // Un film ha una sola stagione con un solo episodio: se ce ne sono
            // di più li accorpiamo mantenendo il primo.
            if let firstSeason = data.series[i].seasons.first,
               let firstEp = firstSeason.episodes.first {
                var ep = firstEp
                ep.number = 1
                data.series[i].seasons = [Season(number: 1, episodes: [ep])]
            }
        }
        save()
    }

    func deleteEpisode(_ id: UUID) {
        for i in data.series.indices {
            for j in data.series[i].seasons.indices {
                data.series[i].seasons[j].episodes.removeAll { $0.id == id }
            }
            data.series[i].seasons.removeAll { $0.episodes.isEmpty }
        }
        data.loose.removeAll { $0.id == id }
        save()
    }

    func relocate(_ id: UUID, to url: URL) {
        update(id) { $0.path = url.path }
        try? FileManager.default.removeItem(at: Paths.thumb(id))
        ThumbCache.invalidate(id)
        thumbReady.remove(id)
        Task { await refreshMetadata() }
    }

    /// Durate mancanti + anteprime, in background.
    func refreshMetadata() async {
        for ep in allEpisodes where !ep.missing {
            var duration = ep.duration
            if duration <= 0 {
                duration = await Media.duration(of: ep.url)
                if duration > 0 { update(ep.id) { $0.duration = duration } }
            }
            // Anteprima solo per i formati leggibili: gli mkv l'avranno dopo la conversione.
            guard !ep.needsConversion, !thumbReady.contains(ep.id) else { continue }
            if await Media.makeThumbnail(for: ep, duration: duration) {
                ThumbCache.invalidate(ep.id)
                thumbReady.insert(ep.id)
            }
        }
    }

    // MARK: - Riproduzione

    func play(_ r: EpisodeRef) {
        guard !r.episode.missing else {
            alert = "Il file di “\(r.episode.title)” non si trova più. "
                  + "Usa “Individua file…” dal menu contestuale."
            return
        }
        if r.episode.needsConversion {
            convert(r.episode)
            if converter.lastError == nil {
                alert = "“\(r.episode.title)” è in formato .\(r.episode.url.pathExtension), "
                      + "che macOS non riproduce direttamente.\n\n"
                      + "L'ho messo in conversione: quando la barra in basso arriva a fine, "
                      + "premi di nuovo play."
            }
            return
        }
        stopPlayback(save: true)

        let item = AVPlayerItem(url: r.episode.url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        // Senza questo AVFoundation applica le preferenze di sistema, che di
        // norma tengono i sottotitoli spenti anche quando il file li contiene.
        p.appliesMediaSelectionCriteriaAutomatically = false
        selectSubtitles(on: item)

        let resume = r.episode.finished ? 0 : r.episode.position
        if resume > 5 {
            p.seek(to: CMTime(seconds: resume, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        }

        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistProgress() }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlaybackEnded() }
        }

        player = p
        nowPlaying = r
        p.play()
    }

    /// Accende la traccia di sottotitoli incorporata nel file, se c'è.
    /// Preferisce l'italiano, poi l'inglese, altrimenti la prima disponibile.
    private func selectSubtitles(on item: AVPlayerItem) {
        guard autoSubtitles else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else { return }
            let options = group.options
            func byLanguage(_ code: String) -> AVMediaSelectionOption? {
                options.first { $0.locale?.language.languageCode?.identifier == code }
            }
            let choice = byLanguage("it") ?? byLanguage("en") ?? options.first
            if let choice { item.select(choice, in: group) }
        }
    }

    /// "Visto" quando manca meno del 3% (min 5s, max 60s): regge sia clip brevi sia film.
    nonisolated static func isFinished(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position >= duration - min(60, max(5, duration * 0.03))
    }

    private func persistProgress() {
        guard let p = player, let r = nowPlaying else { return }
        let t = CMTimeGetSeconds(p.currentTime())
        guard t.isFinite, t > 0 else { return }
        var total = r.episode.duration
        if total <= 0, let d = p.currentItem?.duration, CMTimeGetSeconds(d).isFinite {
            total = CMTimeGetSeconds(d)
        }
        let done = AppModel.isFinished(position: t, duration: total)

        update(r.episode.id) {
            $0.position = t
            if total > 0 { $0.duration = total }
            $0.finished = done
            $0.lastWatched = Date()
        }
        if let fresh = episode(r.episode.id) { nowPlaying?.episode = fresh }
        savedTick &+= 1
    }

    private func handlePlaybackEnded() {
        guard let r = nowPlaying else { return }
        update(r.episode.id) {
            $0.finished = true
            $0.position = $0.duration
            $0.lastWatched = Date()
        }
        if let next = nextEpisode(after: r) {
            play(next)
        } else {
            stopPlayback(save: false)
        }
    }

    func stopPlayback(save persist: Bool = true) {
        if persist { persistProgress() }
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player = nil
        nowPlaying = nil
    }

    // MARK: - Import dei file scaricati da VibraVid

    /// Cattura un nuovo file scaricato. Se il chiamante fornisce un `target`
    /// (l'utente ha scelto "nuova serie X" o "accoda a Y" nel pannello
    /// Scarica), quello vince su qualunque euristica sul path.
    func absorbDownloaded(_ url: URL, target: VibraVidRunner.DownloadTarget? = nil) {
        let parsed = NameParser.parse(url)
        let ep = Episode(
            path: url.path,
            title: parsed.title,
            number: parsed.episode ?? nextEpisodeNumber(for: target) ?? 1
        )

        switch target {
        case .newSeries(let title, let season):
            attach(ep, toSeries: title, season: season)
        case .newMovie(let title):
            attachMovie(ep, title: title)
        case .appendTo(let seriesID, let season):
            if let idx = data.series.firstIndex(where: { $0.id == seriesID }) {
                attachTo(seriesIndex: idx, season: season, ep: ep)
            } else {
                // La serie è stata cancellata a job in corso: fallback nuovo.
                attach(ep, toSeries: parsed.title, season: parsed.season ?? 1)
            }
        case .none:
            // Path tipico di VibraVid: .../Serie/<NomeSerie>/Sxx/<file>
            let seriesTitle = url.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            if let season = parsed.season, !seriesTitle.isEmpty, seriesTitle != "." {
                attach(ep, toSeries: seriesTitle, season: season)
            } else {
                data.loose.append(ep)
            }
        }
        save()
        Task { await refreshMetadata() }
        if ep.needsConversion { convert(ep) }
    }

    /// Cerca il prossimo numero episodio libero nella serie/stagione di
    /// destinazione, per evitare due "1" quando il nome file non contiene S00E00.
    private func nextEpisodeNumber(for target: VibraVidRunner.DownloadTarget?) -> Int? {
        guard let target else { return nil }
        let sIdx: Int?
        let seasonNum: Int
        switch target {
        case .newSeries(let title, let season):
            sIdx = data.series.firstIndex { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            seasonNum = season
        case .newMovie:
            return 1
        case .appendTo(let id, let season):
            sIdx = data.series.firstIndex { $0.id == id }
            seasonNum = season
        }
        guard let sIdx,
              let seaIdx = data.series[sIdx].seasons.firstIndex(where: { $0.number == seasonNum })
        else { return 1 }
        return (data.series[sIdx].seasons[seaIdx].episodes.map(\.number).max() ?? 0) + 1
    }

    /// Aggiunge un film: un contenitore Series con kind=movie e una sola
    /// "stagione" con un episodio (il file). Se esiste già un film con lo
    /// stesso titolo lo sostituisce (fa da re-download).
    private func attachMovie(_ ep: Episode, title: String) {
        var movie = ep
        movie.number = 1
        if let idx = data.series.firstIndex(where: {
            $0.isMovie && $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) {
            data.series[idx].seasons = [Season(number: 1, episodes: [movie])]
        } else {
            let s = Series(title: title.isEmpty ? "Senza titolo" : title,
                           seasons: [Season(number: 1, episodes: [movie])],
                           kind: .movie)
            data.series.append(s)
        }
    }

    private func attachTo(seriesIndex sIdx: Int, season: Int, ep: Episode) {
        if let seaIdx = data.series[sIdx].seasons.firstIndex(where: { $0.number == season }) {
            data.series[sIdx].seasons[seaIdx].episodes.append(ep)
        } else {
            data.series[sIdx].seasons.append(Season(number: season, episodes: [ep]))
            data.series[sIdx].seasons.sort { $0.number < $1.number }
        }
    }

    private func attach(_ ep: Episode, toSeries title: String, season: Int) {
        if let sIdx = data.series.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            if let seaIdx = data.series[sIdx].seasons.firstIndex(where: { $0.number == season }) {
                data.series[sIdx].seasons[seaIdx].episodes.append(ep)
            } else {
                data.series[sIdx].seasons.append(Season(number: season, episodes: [ep]))
                data.series[sIdx].seasons.sort { $0.number < $1.number }
            }
        } else {
            let s = Series(title: title, seasons: [Season(number: season, episodes: [ep])])
            data.series.append(s)
        }
    }

    // MARK: - Apertura dal Finder ("Apri con")

    func openExternal(_ urls: [URL]) {
        guard let url = urls.first else { return }
        if let existing = allEpisodes.first(where: { $0.path == url.path }) {
            play(ref(for: existing))
            return
        }
        let parsed = NameParser.parse(url)
        let ep = Episode(path: url.path, title: parsed.title, number: parsed.episode ?? 1)
        data.loose.append(ep)
        save()
        play(ref(for: ep))
        Task { await refreshMetadata() }
    }
}

// MARK: - Bozza di importazione

struct ImportDraft: Identifiable {
    struct Item: Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var number: Int
    }

    var id = UUID()
    var targetSeriesID: UUID?
    var title: String = ""
    var season: Int = 1
    var seasonName: String = ""
    var items: [Item] = []
    /// Se true, la commitImport crea una Series con kind = .movie (non
    /// consigliato per accodamenti a serie esistenti).
    var isMovie: Bool = false

    mutating func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        let fresh = NameParser.naturalSort(urls.filter { !known.contains($0) })
        var detectedSeason: Int?
        for (offset, url) in fresh.enumerated() {
            let p = NameParser.parse(url)
            if detectedSeason == nil, let s = p.season { detectedSeason = s }
            items.append(Item(url: url, title: p.title, number: p.episode ?? items.count + offset + 1))
        }
        renumberIfNeeded()
        if title.isEmpty { title = NameParser.suggestSeriesTitle(for: items.map(\.url)) }
        if let s = detectedSeason, targetSeriesID == nil { season = s }
    }

    /// Se il rilevamento automatico ha prodotto duplicati, rinumera in ordine di lista.
    mutating func renumberIfNeeded() {
        let numbers = items.map(\.number)
        if Set(numbers).count != numbers.count {
            for i in items.indices { items[i].number = i + 1 }
        }
    }
}

// MARK: - Utility

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
