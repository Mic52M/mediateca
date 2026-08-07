import AppKit
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  ✓ \(label)" : "  ✗ \(label) \(detail)")
    if !ok { failures += 1 }
}

// MARK: 1 — riconoscimento dei nomi file

print("\n[1] Riconoscimento stagione/episodio dai nomi file")
let cases: [(String, Int?, Int?)] = [
    ("Steins;Gate S01E04 [1080p].mkv", 1, 4),
    ("MioAnime_S02E11.mp4", 2, 11),
    ("Serie - Ep 07.mov", nil, 7),
    ("Anime Episodio 12.mp4", nil, 12),
    ("Qualcosa 03.mp4", nil, 3),
]
for (name, season, ep) in cases {
    let p = NameParser.parse(URL(fileURLWithPath: "/tmp/\(name)"))
    check("\(name) → S:\(p.season.map(String.init) ?? "-") E:\(p.episode.map(String.init) ?? "-")",
          p.season == season && p.episode == ep,
          "atteso S:\(season.map(String.init) ?? "-") E:\(ep.map(String.init) ?? "-")")
}

let ordered = NameParser.naturalSort([
    URL(fileURLWithPath: "/tmp/Ep 10.mp4"),
    URL(fileURLWithPath: "/tmp/Ep 2.mp4"),
    URL(fileURLWithPath: "/tmp/Ep 1.mp4"),
])
check("ordinamento naturale (Ep2 prima di Ep10)",
      ordered.map { $0.lastPathComponent } == ["Ep 1.mp4", "Ep 2.mp4", "Ep 10.mp4"])

// MARK: 2 — soglia "visto"

print("\n[2] Soglia “visto”")
check("film 90 min a 30 min → non visto", !AppModel.isFinished(position: 1800, duration: 5400))
check("film 90 min a 89 min → visto", AppModel.isFinished(position: 5340, duration: 5400))
check("clip 15s a 6s → non visto", !AppModel.isFinished(position: 6, duration: 15))
check("clip 15s a 14s → visto", AppModel.isFinished(position: 14, duration: 15))
check("durata sconosciuta → non visto", !AppModel.isFinished(position: 100, duration: 0))

// MARK: 3 — import, stagioni, persistenza

print("\n[3] Import, stagioni e persistenza su disco")

// I test devono girare su una libreria isolata: senza MEDIATECA_HOME
// scriverebbero sulla libreria vera dell'utente.
guard ProcessInfo.processInfo.environment["MEDIATECA_HOME"] != nil else {
    print("✗ MEDIATECA_HOME non impostata: i test rifiutano di toccare la libreria reale.")
    exit(2)
}
try? FileManager.default.removeItem(at: Paths.library)

let realVideos = ((try? FileManager.default.contentsOfDirectory(
    at: URL(fileURLWithPath: NSHomeDirectory() + "/Movies"),
    includingPropertiesForKeys: nil)) ?? [])
    .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .prefix(3)
    .map { $0 }

let model = await AppModel()

var draft = ImportDraft()
draft.add(Array(realVideos))
draft.title = "Anime di Prova"
draft.season = 1
await MainActor.run { model.commitImport(draft) }

var series = await model.data.series
check("serie creata con titolo", series.count == 1 && series[0].title == "Anime di Prova")
check("stagione 1 con \(realVideos.count) episodi",
      series.first?.seasons.first?.number == 1 &&
      series.first?.seasons.first?.episodes.count == realVideos.count)

// seconda stagione nella stessa serie
let sid = series[0].id
var draft2 = ImportDraft(targetSeriesID: sid)
draft2.add(Array(realVideos.prefix(2)))
draft2.season = 2
draft2.seasonName = "Seconda stagione"
await MainActor.run { model.commitImport(draft2) }

series = await model.data.series
check("seconda stagione aggiunta alla stessa serie",
      series.count == 1 && series[0].seasons.count == 2)
check("etichetta stagione personalizzata",
      series[0].seasons.last?.label == "Seconda stagione")

// persistenza: nuova istanza rilegge dal disco
let reloaded = await AppModel()
let rs = await reloaded.data.series
check("libreria riletta da disco dopo riavvio",
      rs.count == 1 && rs[0].seasons.count == 2 && rs[0].title == "Anime di Prova")

// MARK: 4 — ripresa e episodio successivo

print("\n[4] Ripresa e passaggio all'episodio successivo")
let firstEp = series[0].seasons[0].episodes[0]
await MainActor.run {
    model.update(firstEp.id) { $0.duration = 240; $0.position = 137; $0.lastWatched = Date() }
}
let saved = await model.episode(firstEp.id)
check("posizione salvata a 137s", saved?.position == 137)
check("compare in “Continua a guardare”",
      await model.continueWatching.contains { $0.episode.id == firstEp.id })

let ref1 = await model.ref(for: saved!)
let next = await model.nextEpisode(after: ref1)
check("episodio successivo nella stessa stagione",
      next?.episode.id == series[0].seasons[0].episodes[1].id)

let lastOfS1 = series[0].seasons[0].episodes.last!
let nextAcross = await model.nextEpisode(after: model.ref(for: lastOfS1))
check("fine stagione 1 → primo episodio stagione 2",
      nextAcross?.episode.id == series[0].seasons[1].episodes[0].id)

let ep2 = series[0].seasons[0].episodes[1]
await MainActor.run { model.update(ep2.id) { $0.duration = 100; $0.position = 99; $0.finished = true } }
check("episodio visto esce da “Continua a guardare”",
      await !model.continueWatching.contains { $0.episode.id == ep2.id })

// MARK: 5 — anteprime e durate reali

print("\n[5] Anteprime e durate reali (AVFoundation)")
if let probe = realVideos.first {
    let d = await Media.duration(of: probe)
    check("durata letta da \(probe.lastPathComponent): \(formatTime(d))", d > 0)
    let ep = Episode(path: probe.path, title: "test", number: 1)
    try? FileManager.default.removeItem(at: Paths.thumb(ep.id))
    let made = await Media.makeThumbnail(for: ep, duration: d)
    let size = (try? FileManager.default.attributesOfItem(atPath: Paths.thumb(ep.id).path)[.size] as? Int) ?? 0
    check("anteprima JPEG generata (\(size ?? 0) byte)", made && (size ?? 0) > 1000)
    try? FileManager.default.removeItem(at: Paths.thumb(ep.id))
} else {
    check("nessun video di prova trovato in ~/Movies", false)
}

// MARK: 6 — conversione MKV → MP4

print("\n[6] Conversione MKV → MP4")
check("ffmpeg e ffprobe individuati", Converter.isAvailable)

let mkvDir = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/TestAnimeMKV")
let mkvs = ((try? FileManager.default.contentsOfDirectory(at: mkvDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "mkv" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

if mkvs.isEmpty {
    check("file .mkv di prova presenti", false)
} else {
    // Libreria vuota: questa sezione non deve mai vedere episodi delle sezioni precedenti,
    // che puntano a file reali dell'utente.
    try? FileManager.default.removeItem(at: Paths.library)
    let m = await AppModel()
    var d = ImportDraft()
    d.add(mkvs)
    d.title = "MioAnime"
    await MainActor.run { m.commitImport(d) }

    let eps = await m.allEpisodes
    check("mkv riconosciuti come “da convertire”", eps.allSatisfy(\.needsConversion))
    await m.refreshMetadata()
    let withDurations = await m.allEpisodes
    check("durata degli mkv letta comunque (via ffprobe)",
          withDurations.allSatisfy { $0.duration > 0 },
          withDurations.map { formatTime($0.duration) }.joined(separator: ", "))
    check("numeri episodio riconosciuti da “S01E01/S01E02”",
          eps.map(\.number).sorted() == [1, 2])

    // attende la coda di conversione (max 120s)
    let deadline = Date().addingTimeInterval(120)
    while await m.converter.isBusy, Date() < deadline {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    let after = await m.allEpisodes.sorted { $0.number < $1.number }
    check("tutti gli episodi ora puntano a un .mp4",
          after.allSatisfy { $0.url.pathExtension == "mp4" && !$0.needsConversion })
    check("percorso originale conservato",
          after.allSatisfy { $0.originalPath?.hasSuffix(".mkv") == true })
    check("gli originali .mkv non sono stati toccati",
          mkvs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

    for ep in after {
        let dur = await Media.duration(of: ep.url)
        check("“\(ep.title)” riproducibile da AVFoundation (\(formatTime(dur)))", dur > 0)
    }

    // il primo file aveva sottotitoli ASS: devono essere sopravvissuti come mov_text
    if let first = after.first, let probe = Converter.ffprobe {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = ["-v", "error", "-show_entries", "stream=codec_type,codec_name",
                       "-of", "csv=p=0", first.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        check("sottotitoli conservati come mov_text", text.contains("mov_text"), text)
        check("video copiato senza ricodifica (h264 intatto)", text.contains("h264"), text)
    }

    // Pulizia: SOLO dentro la cartella di prova. Mai cancellare per percorso
    // preso dal modello senza verificare che stia nell'area di test.
    let sandbox = mkvDir.resolvingSymlinksInPath().path + "/"
    for ep in after {
        let p = ep.url.resolvingSymlinksInPath().path
        guard p.hasPrefix(sandbox) else {
            print("  ! saltata cancellazione fuori dall'area di test: \(p)")
            continue
        }
        try? FileManager.default.removeItem(at: ep.url)
    }
}


// MARK: 7 — riordino episodi e gestione stagioni

print("\n[7] Riordino episodi e stagioni")
do {
    try? FileManager.default.removeItem(at: Paths.library)
    let m = await AppModel()

    // serie fittizia con 4 episodi in ordine 4,3,2,1
    var s = Series(title: "Riordino")
    var season = Season(number: 1)
    season.episodes = (1...4).reversed().map {
        Episode(path: "/tmp/fake\($0).mp4", title: "Ep \($0)", number: $0)
    }
    s.seasons = [season]
    await MainActor.run { m.data.series = [s]; m.save() }

    func order() async -> [Int] {
        await m.data.series[0].seasons[0].episodes.map(\.number)
    }
    check("ordine iniziale 4,3,2,1", await order() == [4, 3, 2, 1])

    let first = await m.data.series[0].seasons[0].episodes[0]
    await MainActor.run { m.moveEpisode(first.id, by: 1) }
    check("“sposta giù” sul primo → 3,4,2,1", await order() == [3, 4, 2, 1])

    await MainActor.run { m.moveEpisode(first.id, by: -1) }
    check("“sposta su” lo riporta → 4,3,2,1", await order() == [4, 3, 2, 1])

    await MainActor.run { m.moveEpisode(first.id, by: -1) }
    check("“sposta su” sul primo non fa nulla", await order() == [4, 3, 2, 1])

    let last = await m.data.series[0].seasons[0].episodes[3]
    await MainActor.run { m.moveEpisode(last.id, by: 1) }
    check("“sposta giù” sull'ultimo non fa nulla", await order() == [4, 3, 2, 1])

    await MainActor.run { m.moveEpisode(first.id, toIndex: 3) }
    check("trascinamento in fondo → 3,2,1,4", await order() == [3, 2, 1, 4])

    await MainActor.run { m.sortSeasonByNumber(s.id, 1) }
    check("“ordina per numero” → 1,2,3,4", await order() == [1, 2, 3, 4])

    await MainActor.run { m.reverseSeason(s.id, 1) }
    check("“inverti” → 4,3,2,1", await order() == [4, 3, 2, 1])

    await MainActor.run { m.renumberSeasonInOrder(s.id, 1) }
    check("“rinumera nell'ordine attuale” → 1,2,3,4", await order() == [1, 2, 3, 4])

    // spostamento fra stagioni
    let moving = await m.data.series[0].seasons[0].episodes[0]
    let nextNum = await m.nextSeasonNumber(for: s.id)
    check("prossima stagione proposta = 2", nextNum == 2)
    await MainActor.run { m.moveEpisode(moving.id, toSeason: nextNum) }
    let seasons = await m.data.series[0].seasons
    check("nuova stagione 2 creata con 1 episodio",
          seasons.count == 2 && seasons[1].number == 2 && seasons[1].episodes.count == 1)
    check("stagione 1 ora ha 3 episodi", seasons[0].episodes.count == 3)

    await MainActor.run { m.moveEpisode(moving.id, toSeason: 1) }
    let back = await m.data.series[0].seasons
    check("riportato in stagione 1, la stagione vuota sparisce",
          back.count == 1 && back[0].episodes.count == 4)

    // persistenza dell'ordine
    await MainActor.run { m.reverseSeason(s.id, 1) }
    let inMemory = await order()
    let reopened = await AppModel()
    let fromDisk = await reopened.data.series[0].seasons[0].episodes.map(\.number)
    check("l'ordine sopravvive al riavvio (\(fromDisk.map(String.init).joined(separator: ",")))",
          fromDisk == inMemory,
          "in memoria: \(inMemory.map(String.init).joined(separator: ","))")
}

// MARK: ripristino

try? FileManager.default.removeItem(at: Paths.library)

print("\n" + (failures == 0 ? "✓ tutti i test superati" : "✗ \(failures) test falliti"))
exit(failures == 0 ? 0 : 1)
