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
        .alert(removalTitle, isPresented: Binding(
            get: { model.pendingRemoval != nil },
            set: { if !$0 { model.cancelPendingRemoval() } }
        )) {
            Button("Rimuovi", role: .destructive) { model.confirmPendingRemoval() }
            Button("Annulla", role: .cancel) { model.cancelPendingRemoval() }
        } message: {
            Text("La voce “\(model.pendingRemoval?.title ?? "")” verrà tolta dalla libreria. "
               + "I file su disco non vengono toccati.")
        }
    }

    private var removalTitle: String {
        guard let p = model.pendingRemoval else { return "Rimuovere?" }
        return p.isMovie ? "Rimuovere il film?" : "Rimuovere la serie?"
    }
}

// MARK: - Libreria

struct LibraryScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Home", systemImage: "house.fill")
                        .tag(AppModel.SidebarItem.home)
                    Label("Scarica", systemImage: "arrow.down.circle.fill")
                        .tag(AppModel.SidebarItem.download)
                    Label("Impostazioni", systemImage: "gearshape.fill")
                        .tag(AppModel.SidebarItem.settings)
                }

                if !model.tvSeries.isEmpty {
                    Section("Serie tv") {
                        ForEach(model.tvSeries) { s in sidebarRow(for: s) }
                    }
                }
                if !model.movies.isEmpty {
                    Section("Film") {
                        ForEach(model.movies) { s in sidebarRow(for: s) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.background.opacity(0.85))
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.beginImport()
                } label: {
                    Label("Aggiungi contenuto", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(Theme.Spacing.md)
            }
        } detail: {
            switch model.selection {
            case .series(let id):
                if let s = model.series(id) {
                    SeriesDetail(series: s)
                } else {
                    HomeScreen()
                }
            case .download:
                DownloadScreen(runner: model.runner, bridge: model.vibravid)
            case .settings:
                SettingsScreen(bridge: model.vibravid)
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

    @ViewBuilder
    private func sidebarRow(for s: Series) -> some View {
        let icon = s.isMovie ? "film" : "rectangle.stack"
        let movieDuration = s.seasons.first?.episodes.first?.duration ?? 0
        let subtitle = s.isMovie
            ? (movieDuration > 0 ? formatTime(movieDuration) : "film")
            : "\(s.episodeCount) episodi · \(s.seasons.count) stagion\(s.seasons.count == 1 ? "e" : "i")"
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(AppModel.SidebarItem.series(s.id))
        .contextMenu {
            if !s.isMovie {
                Button("Aggiungi episodi…") { model.beginImport(into: s.id) }
            }
            Button(s.isMovie ? "Converti in serie tv" : "Converti in film") {
                model.toggleKind(s.id)
            }
            Divider()
            Button("Rimuovi dalla libreria", role: .destructive) {
                model.requestRemoveSeries(s.id)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {

                if let featured = model.featured {
                    HeroBanner(ref: featured)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.top, Theme.Spacing.md)
                }

                if !model.continueWatching.isEmpty {
                    homeSection("Continua a guardare") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.lg) {
                                ForEach(model.continueWatching) { r in
                                    ContinueCard(ref: r)
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.xl)
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                }

                if model.data.series.isEmpty && model.data.loose.isEmpty {
                    EmptyState()
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                if !model.tvSeries.isEmpty {
                    homeSection("Serie tv") {
                        cardGrid(items: model.tvSeries)
                    }
                }

                if !model.movies.isEmpty {
                    homeSection("Film") {
                        cardGrid(items: model.movies)
                    }
                }

                if !model.data.loose.isEmpty {
                    homeSection("Video singoli") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Spacing.lg)],
                                  alignment: .leading, spacing: Theme.Spacing.xl) {
                            ForEach(model.data.loose) { ep in
                                ContinueCard(ref: model.ref(for: ep),
                                             showRemoveControl: false)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.xl)
                    }
                }

                Spacer(minLength: 40)
            }
        }
        .themedBackground()
        .navigationTitle("Mediateca")
    }

    // MARK: pezzi riusabili

    @ViewBuilder
    private func homeSection<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(.title3).bold()
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Spacing.xl)
            content()
        }
    }

    private func cardGrid(items: [Series]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Spacing.lg)],
                  alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(items) { s in SeriesCard(series: s) }
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

// MARK: - Hero banner in home

private struct HeroBanner: View {
    @EnvironmentObject var model: AppModel
    let ref: EpisodeRef
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Immagine di sfondo grande, poi due overlay: il gradient laterale
            // per la leggibilità del testo, e quello dal basso per rifinire.
            Thumbnail(episodeID: ref.episode.id,
                      ready: model.thumbReady.contains(ref.episode.id))
                .equatable()
                .aspectRatio(21.0/9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))

            Theme.heroOverlay
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
                .allowsHitTesting(false)

            content
                .padding(Theme.Spacing.xxl)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 12)
        .scaleEffect(hovering ? 1.005 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(ref.episode.started ? "CONTINUA" : "IN EVIDENZA")
                    .font(.caption2).bold()
                    .tracking(2)
                    .foregroundStyle(Theme.accent)
                if let seriesID = ref.seriesID, let s = model.series(seriesID) {
                    Text(s.isMovie ? "FILM" : "SERIE TV")
                        .font(.caption2).bold()
                        .tracking(2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(displayTitle)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)

            HStack(spacing: Theme.Spacing.md) {
                if ref.episode.duration > 0 {
                    Label(formatTime(ref.episode.duration), systemImage: "clock")
                }
                if !ref.seasonLabel.isEmpty {
                    Text("S\(ref.seasonNumber)E\(ref.episode.number)")
                }
                if ref.episode.started {
                    Text("Restano \(formatTime(ref.episode.remaining))")
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)

            if ref.episode.progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * ref.episode.progress)
                    }
                }
                .frame(width: 320, height: 4)
            }

            HStack(spacing: Theme.Spacing.md) {
                Button {
                    model.play(ref)
                } label: {
                    Label(ref.episode.started ? "Riprendi" : "Riproduci",
                          systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let seriesID = ref.seriesID {
                    Button {
                        model.selection = .series(seriesID)
                    } label: {
                        Label("Vai alla serie", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                }
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var displayTitle: String {
        if let seriesID = ref.seriesID, let s = model.series(seriesID) { return s.title }
        return ref.episode.title
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 110, height: 110)
                Image(systemName: "film.stack")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .shadow(color: Theme.accent.opacity(0.25), radius: 18)

            Text("La libreria è vuota")
                .font(.title2).bold()
                .foregroundStyle(Theme.text)

            Text("Aggiungi la tua prima serie o film, trascina qui i video, o vai su “Scarica”.")
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: Theme.Spacing.md) {
                Button {
                    model.beginImport()
                } label: {
                    Label("Aggiungi contenuto", systemImage: "plus")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.selection = .download
                } label: {
                    Label("Scarica online", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
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
    @State private var hovering = false

    var showRemoveControl: Bool = true

    private let cardWidth: CGFloat = 260
    private let cardHeight: CGFloat = 146

    var body: some View {
        Button {
            model.play(ref)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                thumbnail
                info
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Riproduci") { model.play(ref) }
            Divider()
            if ref.episode.started {
                Button("Rimuovi da “Continua a guardare”") {
                    model.dismissFromContinueWatching(ref.episode.id)
                }
            }
            Button(ref.episode.finished ? "Segna come da vedere" : "Segna come visto") {
                model.update(ref.episode.id) {
                    $0.finished.toggle()
                    $0.position = $0.finished ? $0.duration : 0
                    $0.lastWatched = Date()
                }
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            Thumbnail(episodeID: ref.episode.id,
                      ready: model.thumbReady.contains(ref.episode.id))
                .equatable()
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

            // Gradient sempre presente ma lieve, si intensifica al passaggio.
            LinearGradient(
                colors: [.clear, .black.opacity(hovering ? 0.55 : 0.35)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(width: cardWidth, height: cardHeight)

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white, Theme.accent)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .padding(.bottom, ref.episode.progress > 0 ? 18 : 12)
            }

            if ref.episode.progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.22))
                        Rectangle().fill(Theme.accent)
                            .frame(width: geo.size.width * ref.episode.progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if ref.episode.missing {
                badge("File mancante", icon: "exclamationmark.triangle.fill",
                      color: Theme.danger)
            } else if showRemoveControl && ref.episode.started {
                removeButton
                    .padding(6)
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: hovering)
            }
        }
        .overlay(alignment: .topLeading) {
            if ref.episode.finished {
                Label("Visto", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.success)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(hovering ? 0.35 : 0.2),
                radius: hovering ? 14 : 6, x: 0, y: hovering ? 8 : 3)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ref.episode.title)
                .lineLimit(1).font(.callout).bold()
                .foregroundStyle(Theme.text)
            Text(ref.episode.remaining > 0 && ref.episode.position > 0
                 ? "\(ref.subtitle) · restano \(formatTime(ref.episode.remaining))"
                 : ref.subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.iconOnly)
            .padding(6)
            .background(.black.opacity(0.6), in: Circle())
            .foregroundStyle(color)
            .padding(6)
    }

    private var removeButton: some View {
        Button {
            model.dismissFromContinueWatching(ref.episode.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.78), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Rimuovi da “Continua a guardare”")
    }
}

struct SeriesCard: View {
    @EnvironmentObject var model: AppModel
    let series: Series
    @State private var hovering = false

    var body: some View {
        Button {
            model.selection = .series(series.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                thumbnail
                info
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            if !series.isMovie {
                Button("Aggiungi episodi…") { model.beginImport(into: series.id) }
            }
            Button(series.isMovie ? "Converti in serie tv" : "Converti in film") {
                model.toggleKind(series.id)
            }
            Button("Rimuovi dalla libreria", role: .destructive) {
                model.requestRemoveSeries(series.id)
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            Thumbnail(episodeID: series.firstEpisode?.id ?? series.id,
                      ready: model.thumbReady.contains(series.firstEpisode?.id ?? series.id))
                .equatable()
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(minHeight: 120)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(hovering ? 0.5 : 0.28)],
                startPoint: .center, endPoint: .bottom
            )

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white, Theme.accent)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .padding(.bottom, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .overlay(alignment: .topLeading) {
            if series.isMovie {
                Text("FILM")
                    .chip(color: Theme.accent)
                    .padding(8)
            }
        }
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.15),
                radius: hovering ? 12 : 5, x: 0, y: hovering ? 8 : 3)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(series.title)
                .font(.callout).bold()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(cardSubtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var cardSubtitle: String {
        if series.isMovie {
            let d = series.firstEpisode?.duration ?? 0
            return d > 0 ? "Film · \(formatTime(d))" : "Film"
        }
        return "\(series.seasons.count) stagion\(series.seasons.count == 1 ? "e" : "i") · \(series.episodeCount) ep."
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
        if series.isMovie {
            MovieDetail(series: series)
        } else {
            seriesBody
        }
    }

    private var seriesBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                seriesHero
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.md)

                if let season {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack(spacing: Theme.Spacing.md) {
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

                            Spacer()

                            Text("Trascina o usa le frecce per riordinare.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, ep in
                                EpisodeRow(episode: ep,
                                           series: series,
                                           season: season,
                                           index: index)
                                if ep.id != season.episodes.last?.id {
                                    Divider().overlay(Theme.border)
                                }
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                                .strokeBorder(Theme.border, lineWidth: 0.5)
                        )
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                }

                Spacer(minLength: 30)
            }
        }
        .themedBackground()
        .navigationTitle(series.title)
    }

    private var seriesHero: some View {
        ZStack(alignment: .bottomLeading) {
            Thumbnail(episodeID: series.firstEpisode?.id ?? series.id,
                      ready: model.thumbReady.contains(series.firstEpisode?.id ?? series.id))
                .equatable()
                .aspectRatio(21.0/9.0, contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
            Theme.heroOverlay
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("SERIE TV")
                    .font(.caption2).bold().tracking(2)
                    .foregroundStyle(Theme.accent)

                Text(series.title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)

                Text("\(series.seasons.count) stagion\(series.seasons.count == 1 ? "e" : "i") · \(series.episodeCount) episodi")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.callout)

                HStack(spacing: Theme.Spacing.md) {
                    if let r = resumeTarget {
                        Button {
                            model.play(r)
                        } label: {
                            Label(r.episode.started
                                  ? "Riprendi S\(r.seasonNumber)E\(r.episode.number)"
                                  : "Riproduci S\(r.seasonNumber)E\(r.episode.number)",
                                  systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Button {
                        model.beginImport(into: series.id, season: seasonNumber)
                    } label: {
                        Label("Aggiungi episodi", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.Spacing.xxl)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }
}

// MARK: - Vista dedicata al film

/// Dettaglio del film: niente stagioni, niente lista episodi. L'anteprima è
/// grande, il tasto Riproduci è dominante, sotto ci sono le informazioni
/// utili (durata, stato, formato).
struct MovieDetail: View {
    @EnvironmentObject var model: AppModel
    let series: Series

    private var episode: Episode? { series.seasons.first?.episodes.first }
    private var ref: EpisodeRef? { episode.map { model.ref(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                movieHero
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.md)

                if let ep = episode {
                    HStack(spacing: Theme.Spacing.md) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([ep.url])
                        } label: {
                            Label("Mostra nel Finder", systemImage: "folder")
                        }
                        Button(ep.finished ? "Segna come da vedere" : "Segna come visto") {
                            model.update(ep.id) {
                                $0.finished.toggle()
                                $0.position = $0.finished ? $0.duration : 0
                                $0.lastWatched = Date()
                            }
                        }
                        Spacer()
                        Button("Rimuovi dalla libreria", role: .destructive) {
                            model.requestRemoveSeries(series.id)
                        }
                        .tint(Theme.danger)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                    .padding(.horizontal, Theme.Spacing.xl)
                }

                Spacer(minLength: 30)
            }
        }
        .themedBackground()
        .navigationTitle(series.title)
    }

    private var movieHero: some View {
        ZStack(alignment: .bottomLeading) {
            Thumbnail(
                episodeID: episode?.id ?? series.id,
                ready: model.thumbReady.contains(episode?.id ?? series.id)
            )
            .equatable()
            .aspectRatio(21.0/9.0, contentMode: .fill)
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))

            Theme.heroOverlay
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("FILM")
                    .font(.caption2).bold().tracking(2)
                    .foregroundStyle(Theme.accent)

                Text(series.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)

                if let ep = episode {
                    HStack(spacing: Theme.Spacing.md) {
                        if ep.duration > 0 {
                            Label(formatTime(ep.duration), systemImage: "clock")
                        }
                        if ep.finished {
                            Label("Visto", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Theme.success)
                        } else if ep.started {
                            Label("Restano \(formatTime(ep.remaining))",
                                  systemImage: "arrow.uturn.forward")
                                .foregroundStyle(Theme.accent)
                        }
                        if ep.missing {
                            Label("File mancante", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.danger)
                        }
                        if ep.needsConversion {
                            Label(".\(ep.url.pathExtension) da convertire",
                                  systemImage: "wand.and.rays")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.callout).foregroundStyle(Theme.textSecondary)

                    if ep.progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.18))
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * ep.progress)
                            }
                        }
                        .frame(width: 320, height: 4)
                    }

                    HStack(spacing: Theme.Spacing.md) {
                        Button {
                            if let r = ref { model.play(r) }
                        } label: {
                            Label(ep.started ? "Riprendi" : "Riproduci",
                                  systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(ep.missing)

                        if ep.progress > 0 {
                            Button {
                                model.update(ep.id) {
                                    $0.position = 0
                                    $0.finished = false
                                }
                            } label: {
                                Label("Ricomincia", systemImage: "backward.end")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.white)
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.Spacing.xxl)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
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
