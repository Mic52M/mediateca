import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    /// Un unico alert: due `.alert` sulla stessa vista si contendono la
    /// presentazione e fanno lampeggiare la finestra.
    private var alertText: String? {
        model.alert ?? model.converter.lastError ?? model.converter.notice
    }

    var body: some View {
        // Radice stabile: attaccare sheet e alert a un `Group` con contenuto
        // condizionale faceva ripresentare il pannello a ogni cambio di stato.
        ZStack {
            LibraryScreen()
                .opacity(model.nowPlaying == nil ? 1 : 0)
                .allowsHitTesting(model.nowPlaying == nil)
            if model.nowPlaying != nil {
                PlayerScreen()
            }
        }
        // La barra della finestra esiste solo in libreria: durante la visione
        // sopra il video non resta nulla.
        .toolbar(model.nowPlaying == nil ? .visible : .hidden, for: .windowToolbar)
        .background(WindowChrome(immersive: model.nowPlaying != nil,
                                 chromeVisible: model.nowPlaying == nil || model.chromeVisible))
        .sheet(item: $model.importer) { draft in
            ImportSheet(draft: draft)
                .environmentObject(model)
        }
        .alert("Mediateca", isPresented: Binding(
            get: { alertText != nil },
            set: {
                if !$0 {
                    model.alert = nil
                    model.converter.lastError = nil
                    model.converter.notice = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                model.alert = nil
                model.converter.lastError = nil
                model.converter.notice = nil
            }
        } message: {
            Text(alertText ?? "")
        }
    }
}

// MARK: - Libreria

struct LibraryScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("Home", systemImage: "house")
                    .tag(AppModel.SidebarItem.home)

                Section("Le tue serie") {
                    ForEach(model.data.series) { s in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).lineLimit(1)
                                Text("\(s.episodeCount) episodi · \(s.seasons.count) stagion\(s.seasons.count == 1 ? "e" : "i")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "rectangle.stack")
                        }
                        .tag(AppModel.SidebarItem.series(s.id))
                        .contextMenu {
                            Button("Aggiungi episodi…") { model.beginImport(into: s.id) }
                            Divider()
                            Button("Rimuovi dalla libreria", role: .destructive) {
                                model.deleteSeries(s.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.beginImport()
                } label: {
                    Label("Aggiungi serie…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(10)
            }
        } detail: {
            switch model.selection {
            case .series(let id):
                if let s = model.series(id) {
                    SeriesDetail(series: s)
                } else {
                    HomeScreen()
                }
            default:
                HomeScreen()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConversionBar(converter: model.converter)
                .environmentObject(model)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let d = item as? Data,
                   let u = URL(dataRepresentation: d, relativeTo: nil) {
                    urls.append(u)
                }
            }
            let videos = VideoTypes.collect(urls)
            if !videos.isEmpty { model.beginImport(urls: videos) }
        }
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !model.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continua a guardare").font(.title2).bold()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(model.continueWatching) { r in
                                    ContinueCard(ref: r)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }

                if model.data.series.isEmpty && model.data.loose.isEmpty {
                    EmptyState()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Le tue serie").font(.title2).bold()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(model.data.series) { s in
                                SeriesCard(series: s)
                            }
                        }
                    }

                    if !model.data.loose.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Video singoli").font(.title2).bold()
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)],
                                      alignment: .leading, spacing: 20) {
                                ForEach(model.data.loose) { ep in
                                    ContinueCard(ref: model.ref(for: ep))
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Mediateca")
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("La libreria è vuota").font(.title3).bold()
            Text("Trascina qui i tuoi episodi, oppure aggiungi una serie e dai un titolo e una stagione.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Aggiungi serie…") { model.beginImport() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Card

struct Thumbnail: View, Equatable {
    let episodeID: UUID
    /// Cambia una sola volta, quando l'anteprima diventa disponibile.
    let ready: Bool

    static func == (a: Thumbnail, b: Thumbnail) -> Bool {
        a.episodeID == b.episodeID && a.ready == b.ready
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.18))
            if let img = ThumbCache.image(for: episodeID) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ContinueCard: View {
    @EnvironmentObject var model: AppModel
    let ref: EpisodeRef

    var body: some View {
        Button {
            model.play(ref)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    Thumbnail(episodeID: ref.episode.id, ready: model.thumbReady.contains(ref.episode.id))
                        .equatable()
                        .frame(width: 236, height: 133)
                        .clipped()
                    if ref.episode.progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.3))
                                Rectangle().fill(Color.accentColor)
                                    .frame(width: geo.size.width * ref.episode.progress)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .frame(width: 236, height: 133)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if ref.episode.missing {
                        Label("File mancante", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .padding(6)
                            .background(.black.opacity(0.6), in: Circle())
                            .foregroundStyle(.orange)
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.episode.title).lineLimit(1).font(.callout).bold()
                    Text(ref.episode.remaining > 0 && ref.episode.position > 0
                         ? "\(ref.subtitle) · restano \(formatTime(ref.episode.remaining))"
                         : ref.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 236, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SeriesCard: View {
    @EnvironmentObject var model: AppModel
    let series: Series

    var body: some View {
        Button {
            model.selection = .series(series.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(episodeID: series.firstEpisode?.id ?? series.id,
                          ready: model.thumbReady.contains(series.firstEpisode?.id ?? series.id))
                    .equatable()
                    .frame(height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(series.title).font(.callout).bold().lineLimit(1)
                Text("\(series.seasons.count) stagion\(series.seasons.count == 1 ? "e" : "i") · \(series.episodeCount) ep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Aggiungi episodi…") { model.beginImport(into: series.id) }
            Button("Rimuovi dalla libreria", role: .destructive) { model.deleteSeries(series.id) }
        }
    }
}

// MARK: - Dettaglio serie

struct SeriesDetail: View {
    @EnvironmentObject var model: AppModel
    let series: Series
    @State private var seasonNumber: Int = -1

    private var season: Season? {
        series.seasons.first { $0.number == seasonNumber } ?? series.seasons.first
    }

    private var resumeTarget: EpisodeRef? {
        let eps = series.seasons.flatMap(\.episodes)
        if let started = eps.filter(\.started)
            .sorted(by: { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }).first {
            return model.ref(for: started)
        }
        if let next = eps.first(where: { !$0.finished }) { return model.ref(for: next) }
        return eps.first.map { model.ref(for: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    Thumbnail(episodeID: series.firstEpisode?.id ?? series.id,
                              ready: model.thumbReady.contains(series.firstEpisode?.id ?? series.id))
                        .equatable()
                        .frame(width: 260, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(series.title).font(.largeTitle).bold()
                        Text("\(series.seasons.count) stagion\(series.seasons.count == 1 ? "e" : "i") · \(series.episodeCount) episodi")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let r = resumeTarget {
                                Button {
                                    model.play(r)
                                } label: {
                                    Label(r.episode.started
                                          ? "Riprendi S\(r.seasonNumber)E\(r.episode.number)"
                                          : "Riproduci S\(r.seasonNumber)E\(r.episode.number)",
                                          systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            Button {
                                model.beginImport(into: series.id, season: seasonNumber)
                            } label: {
                                Label("Aggiungi episodi", systemImage: "plus")
                            }
                            .controlSize(.large)
                        }
                    }
                    Spacer()
                }

                if let season {
                    HStack(spacing: 12) {
                        Picker("Stagione", selection: Binding(
                            get: { season.number },
                            set: { seasonNumber = $0 }
                        )) {
                            ForEach(series.seasons) { s in
                                Text("\(s.label)  (\(s.episodes.count) ep.)").tag(s.number)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 240)

                        Menu {
                            Button("Ordina per numero episodio") {
                                model.sortSeasonByNumber(series.id, season.number)
                            }
                            Button("Inverti l'ordine") {
                                model.reverseSeason(series.id, season.number)
                            }
                            Divider()
                            Button("Rinumera 1…\(season.episodes.count) nell'ordine attuale") {
                                model.renumberSeasonInOrder(series.id, season.number)
                            }
                        } label: {
                            Label("Ordina", systemImage: "arrow.up.arrow.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Text("Trascina le righe, o usa le frecce che compaiono passandoci sopra.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, ep in
                            EpisodeRow(episode: ep,
                                       series: series,
                                       season: season,
                                       index: index)
                            if ep.id != season.episodes.last?.id { Divider() }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(series.title)
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var model: AppModel
    let episode: Episode
    let series: Series
    let season: Season
    let index: Int
    @State private var hovering = false
    @State private var dropTargeted = false

    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == season.episodes.count - 1 }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                Thumbnail(episodeID: episode.id, ready: model.thumbReady.contains(episode.id))
                    .equatable()
                    .frame(width: 142, height: 80)
                    .clipped()
                if episode.progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * episode.progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(width: 142, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if hovering {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(episode.number).").foregroundStyle(.secondary).monospacedDigit()
                    Text(episode.title).bold().lineLimit(1)
                    if episode.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                    if episode.missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                if let state = model.converter.state(for: episode.id), state != .done {
                    ConversionBadge(state: state)
                } else if episode.missing {
                    Text("File non trovato — spostato o rinominato")
                        .font(.caption).foregroundStyle(.secondary)
                } else if episode.needsConversion {
                    Label("Da convertire (.\(episode.url.pathExtension))",
                          systemImage: "wand.and.rays")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(episode.started
                         ? "restano \(formatTime(episode.remaining)) di \(formatTime(episode.duration))"
                         : formatTime(episode.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            // Frecce di riordino: compaiono solo al passaggio del mouse.
            HStack(spacing: 2) {
                Button {
                    model.moveEpisode(episode.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(isFirst)
                .help("Sposta su")

                Button {
                    model.moveEpisode(episode.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(isLast)
                .help("Sposta giù")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0.25)
                .help("Trascina per riordinare")
        }
        .padding(10)
        .contentShape(Rectangle())
        .background(alignment: .top) {
            if dropTargeted {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { model.play(model.ref(for: episode)) }
        .onDrag {
            NSItemProvider(object: episode.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String, let dragged = UUID(uuidString: raw) else { return }
                Task { @MainActor in model.moveEpisode(dragged, toIndex: index) }
            }
            return true
        }
        .contextMenu {
            Button(episode.finished ? "Segna come da vedere" : "Segna come visto") {
                model.update(episode.id) {
                    $0.finished.toggle()
                    $0.position = $0.finished ? $0.duration : 0
                    $0.lastWatched = Date()
                }
            }
            Button("Riparti dall'inizio") {
                model.update(episode.id) { $0.position = 0; $0.finished = false }
            }
            Divider()
            Button("Sposta su") { model.moveEpisode(episode.id, by: -1) }
                .disabled(isFirst)
            Button("Sposta giù") { model.moveEpisode(episode.id, by: 1) }
                .disabled(isLast)
            Menu("Sposta nella stagione") {
                ForEach(series.seasons) { s in
                    Button(s.label) { model.moveEpisode(episode.id, toSeason: s.number) }
                        .disabled(s.number == season.number)
                }
                Divider()
                Button("Nuova stagione \(model.nextSeasonNumber(for: series.id))") {
                    model.moveEpisode(episode.id, toSeason: model.nextSeasonNumber(for: series.id))
                }
            }
            Divider()
            if episode.needsConversion {
                Button("Converti in MP4") { model.convert(episode) }
            }
            if let original = episode.originalPath {
                Button("Mostra l'originale nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: original)])
                }
            }
            Button("Mostra nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([episode.url])
            }
            if episode.missing {
                Button("Individua file…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = VideoTypes.contentTypes
                    panel.allowsOtherFileTypes = true
                    panel.message = "Seleziona il file per “\(episode.title)”"
                    if panel.runModal() == .OK, let u = panel.url {
                        model.relocate(episode.id, to: u)
                    }
                }
            }
            Divider()
            Button("Rimuovi dalla libreria", role: .destructive) {
                model.deleteEpisode(episode.id)
            }
        }
    }
}

// MARK: - Player

struct PlayerScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var hideTask: Task<Void, Never>?
    @State private var monitor: Any?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let player = model.player {
                NativePlayer(player: player)
            }
            if model.chromeVisible {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            reveal()
            installMonitor()
        }
        .onDisappear {
            hideTask?.cancel()
            removeMonitor()
            model.chromeVisible = true      // la libreria riappare con la sua barra
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                model.stopPlayback()
            } label: {
                Label("Libreria", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)

            if let r = model.nowPlaying {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.episode.title).font(.headline)
                    Text(r.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            if let r = model.nowPlaying, let next = model.nextEpisode(after: r) {
                Button {
                    model.play(next)
                    reveal()
                } label: {
                    Label("Successivo", systemImage: "forward.end.fill")
                }
                .buttonStyle(.plain)
                .help("Vai a S\(next.seasonNumber)E\(next.episode.number)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .background {
            LinearGradient(colors: [.black.opacity(0.75), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: Comparsa e scomparsa

    /// Mostra la barra e riavvia il conto alla rovescia per nasconderla.
    private func reveal() {
        hideTask?.cancel()
        if !model.chromeVisible {
            withAnimation(.easeOut(duration: 0.18)) { model.chromeVisible = true }
        }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.35)) { model.chromeVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Qualsiasi movimento del mouse o tasto premuto fa riapparire la barra.
    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .keyDown, .scrollWheel, .leftMouseDown]
        ) { event in
            let handled: Bool = MainActor.assumeIsolated {
                // Esc torna alla libreria, ma solo se non si è a tutto schermo:
                // lì il tasto serve a uscire dallo schermo intero.
                if event.type == .keyDown, event.keyCode == 53,
                   let win = NSApp.keyWindow, !win.styleMask.contains(.fullScreen) {
                    model.stopPlayback()
                    return true
                }
                reveal()
                return false
            }
            return handled ? nil : event
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Adatta la finestra alla visione: titolo e barra spariscono, il contenuto
/// arriva fino al bordo superiore, e i pulsanti del semaforo si dissolvono
/// insieme alla barra (restano cliccabili, così la finestra è sempre chiudibile).
struct WindowChrome: NSViewRepresentable {
    var immersive: Bool
    var chromeVisible: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.acceptsMouseMovedEvents = true

            if immersive {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            } else {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
            }

            let alpha: CGFloat = (!immersive || chromeVisible) ? 1 : 0
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.animator().alphaValue = alpha
            }
        }
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.allowsPictureInPicturePlayback = true
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        v.updatesNowPlayingInfoCenter = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
