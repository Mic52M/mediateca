import AppKit
import SwiftUI

/// Pannello "Scarica": due modalità (ricerca sui provider + URL diretto) con
/// console live e barra di stato del sottoprocesso.
struct DownloadScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: VibraVidRunner
    @ObservedObject var bridge: VibraVidBridge

    enum Mode: String, CaseIterable, Identifiable {
        case search = "Cerca"
        case url = "URL diretto"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .search

    init(runner: VibraVidRunner, bridge: VibraVidBridge) {
        self.runner = runner
        self.bridge = bridge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)

            if !bridge.isInstalled {
                installationMissing
            } else {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24).padding(.top, 16)
                .frame(maxWidth: 340, alignment: .leading)

                Group {
                    switch mode {
                    case .search: SearchForm(runner: runner, bridge: bridge)
                    case .url:    DirectURLForm(runner: runner)
                    }
                }
                .padding(24)

                Divider().overlay(Theme.border)
                if let prompt = runner.pendingPrompt {
                    PromptPanel(prompt: prompt, runner: runner)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.top, Theme.Spacing.md)
                    Divider().overlay(Theme.border).padding(.top, Theme.Spacing.md)
                }
                logConsole
            }
        }
        .themedBackground()
        .navigationTitle("Scarica")
    }

    // MARK: Header e stato

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scarica").font(.title2).bold()
                Text(statusLine)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if runner.isRunning {
                ProgressView().controlSize(.small)
                Button("Annulla") { runner.cancel() }
                    .controlSize(.large)
            }
        }
        .padding(24)
    }

    private var statusLine: String {
        switch runner.phase {
        case .idle:      return "Pronto"
        case .running:   return "Download in corso…"
        case .cancelled: return "Annullato"
        case .done(let n): return n == 0 ? "Completato" : "Terminato con codice \(n)"
        case .failed(let m): return "Errore: \(m)"
        }
    }

    private var installationMissing: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("VibraVid non trovato").font(.title3).bold()
            Text("Cerco un'installazione in \(bridge.installDir.path). "
               + "Puoi cambiare il percorso da Impostazioni → Percorso VibraVid.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Apri Impostazioni") { model.selection = .settings }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Console

    private var logConsole: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !runner.downloadedFiles.isEmpty {
                    Text("\(runner.downloadedFiles.count) file scaricati")
                        .font(.caption).foregroundStyle(.green)
                }
                Button("Svuota") { runner.clearLog() }.controlSize(.small)
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 6)

            LogConsoleView(
                text: runner.log.isEmpty ? "In attesa di comandi…" : runner.log,
                dimmed: runner.log.isEmpty
            )
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Console veloce basata su NSTextView

/// SwiftUI `Text` rirenderizza tutta la stringa a ogni aggiornamento: con log
/// da decine di migliaia di caratteri manda in stallo il main thread. Un
/// NSTextView riusa il proprio layout manager ed è progettato apposta per
/// output di questo tipo.
private struct LogConsoleView: NSViewRepresentable {
    let text: String
    let dimmed: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isRichText = false
        text.usesFontPanel = false
        text.drawsBackground = true
        text.backgroundColor = NSColor.textBackgroundColor
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView,
              let storage = view.textStorage else { return }
        let color: NSColor = dimmed ? .secondaryLabelColor : .labelColor
        let current = storage.string

        guard current != text else {
            if view.textColor != color { view.textColor = color }
            return
        }

        let stickToBottom: Bool = {
            guard let clip = scroll.contentView as NSClipView? else { return true }
            return (clip.documentVisibleRect.maxY + 40) >= view.frame.height
        }()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        // Se il testo nuovo è un'estensione del precedente (caso comune con
        // log che cresce), appendiamo solo la differenza — molto più veloce
        // di riassegnare l'intera stringa a ogni tick.
        if text.hasPrefix(current) {
            let appended = String(text.dropFirst(current.count))
            if !appended.isEmpty {
                storage.append(NSAttributedString(string: appended, attributes: attrs))
            }
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        view.textColor = color

        if stickToBottom {
            view.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - Ricerca

private struct SearchForm: View {
    @ObservedObject var runner: VibraVidRunner
    @ObservedObject var bridge: VibraVidBridge

    @EnvironmentObject var model: AppModel
    @State private var query: String = ""
    @State private var providerID: Int = 0
    @State private var useGlobal = false
    @State private var category: Int = 0     // 0 = tutte
    @State private var trackPreset: String = ""
    @State private var target = DestinationChoice()

    // I preset accettati dalla CLI --tracks.
    private let presets: [(key: String, label: String)] = [
        ("",   "Usa le impostazioni del config"),
        ("1",  "Doppiaggio (qualunque)"),
        ("2",  "Doppiaggio italiano"),
        ("3",  "Doppiaggio inglese"),
        ("4",  "Doppiaggio in tutte le lingue"),
        ("5",  "Lingua originale"),
        ("6",  "Originale + sub italiano"),
        ("7",  "Originale + sub inglese"),
        ("8",  "Originale + tutti i sub"),
        ("9",  "Multi (audio + sub)"),
        ("10", "Multi italiano"),
        ("11", "Multi inglese"),
        ("12", "Multi in tutte le lingue"),
    ]

    private let categories: [(id: Int, label: String)] = [
        (0, "Tutte"),
        (1, "Anime"),
        (2, "Film & Serie"),
        (3, "Serie"),
        (4, "Film"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Cerca un titolo (es. steins gate)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit { start() }

                Toggle("Ricerca globale", isOn: $useGlobal)
                    .help("Cerca su tutti i siti, poi ti chiede quale scegliere nella console.")
            }

            HStack(spacing: 14) {
                if useGlobal {
                    Picker("Categoria", selection: $category) {
                        ForEach(categories, id: \.id) { c in Text(c.label).tag(c.id) }
                    }
                    .frame(width: 260)
                } else {
                    Picker("Sito", selection: $providerID) {
                        ForEach(bridge.providers) { p in
                            Text("\(p.display)  ·  \(labelFor(p.category))").tag(p.index)
                        }
                    }
                    .frame(width: 340)
                }

                Picker("Tracce", selection: $trackPreset) {
                    ForEach(presets, id: \.key) { p in Text(p.label).tag(p.key) }
                }
                .frame(width: 300)
            }

            DestinationPicker(choice: $target, suggestedTitle: query, allSeries: model.data.series)

            HStack {
                Button {
                    start()
                } label: {
                    Label("Avvia ricerca", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)

                Text("Titolo, stagione ed episodi si scelgono sotto, appena VibraVid li chiede.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func labelFor(_ category: String) -> String {
        switch category.lowercased() {
        case "anime": return "anime"
        case "film_serie": return "film e serie"
        case "serie": return "serie"
        case "song": return "musica"
        default: return category
        }
    }

    private func start() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        runner.pendingTarget = target.resolve(suggestedTitle: q)
        if useGlobal {
            runner.globalSearch(query: q, category: category == 0 ? nil : category)
        } else {
            let name = bridge.providers.first { $0.index == providerID }?.name ?? "\(providerID)"
            runner.searchAndDownload(
                query: q, siteName: name,
                trackPresetKey: trackPreset.isEmpty ? nil : trackPreset)
        }
    }
}

// MARK: - URL diretto

private struct DirectURLForm: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: VibraVidRunner

    @State private var url = ""
    @State private var output = ""
    @State private var headerText = ""
    @State private var licenseURL = ""
    @State private var licenseHeaderText = ""
    @State private var keyText = ""
    @State private var drm = "auto"
    @State private var target = DestinationChoice()

    private let drmOptions = ["auto", "widevine", "playready"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("URL sorgente") {
                TextField("https://…/stream.m3u8", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            row("File di output (opzionale)") {
                TextField("percorso/nome-file  (estensione automatica se omessa)", text: $output)
                    .textFieldStyle(.roundedBorder)
            }
            row("Header HTTP") {
                TextEditor(text: $headerText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 66)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }

            DestinationPicker(choice: $target,
                              suggestedTitle: suggestedTitle,
                              allSeries: model.data.series)

            DisclosureGroup("Opzioni DRM") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Sistema DRM").frame(width: 150, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $drm) {
                            ForEach(drmOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Spacer()
                    }
                    row("URL server licenza") {
                        TextField("https://…/license", text: $licenseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("Header per la licenza") {
                        TextEditor(text: $licenseHeaderText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }
                    row("Chiavi KID:KEY") {
                        TextEditor(text: $keyText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Button {
                    start()
                } label: {
                    Label("Avvia download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)

                Text("Un valore per riga. Formato: Chiave: valore")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }

    /// Nome che compare come default nel selettore serie: quello dell'output
    /// se l'utente l'ha impostato, altrimenti l'ultimo pezzo dell'URL.
    private var suggestedTitle: String {
        if !output.isEmpty { return (output as NSString).lastPathComponent }
        return (url.split(separator: "/").last.map(String.init) ?? "")
            .split(separator: "?").first.map(String.init) ?? ""
    }

    private func start() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        runner.pendingTarget = target.resolve(suggestedTitle: suggestedTitle)
        runner.directDownload(
            url: u,
            output: output.trimmingCharacters(in: .whitespaces),
            headers: lines(headerText),
            licenseURL: licenseURL.trimmingCharacters(in: .whitespaces),
            licenseHeaders: lines(licenseHeaderText),
            keys: lines(keyText),
            drm: drm)
    }

    private func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Scelta destinazione

/// Stato editabile del pannello destinazione. Vive fuori dal picker così può
/// sopravvivere ai suoi re-render e essere passato al runner al momento
/// dell'avvio.
struct DestinationChoice: Equatable {
    enum Mode: String, CaseIterable { case movie, newSeries, appendTo }
    var mode: Mode = .newSeries
    var newTitle: String = ""
    var appendSeriesID: UUID?
    var season: Int = 1

    /// Trasforma le scelte in un `DownloadTarget` concreto per il runner. Se
    /// il nome della nuova serie/film è vuoto, si usa il titolo suggerito.
    func resolve(suggestedTitle: String) -> VibraVidRunner.DownloadTarget {
        let effectiveTitle = newTitle.trimmingCharacters(in: .whitespaces).isEmpty
            ? suggestedTitle.trimmingCharacters(in: .whitespaces)
            : newTitle.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .movie:
            return .newMovie(title: effectiveTitle.isEmpty ? "Senza titolo" : effectiveTitle)
        case .newSeries:
            return .newSeries(title: effectiveTitle.isEmpty ? "Senza titolo" : effectiveTitle,
                              season: max(1, season))
        case .appendTo:
            if let id = appendSeriesID {
                return .appendTo(seriesID: id, season: max(1, season))
            }
            return .newSeries(title: effectiveTitle.isEmpty ? "Senza titolo" : effectiveTitle,
                              season: max(1, season))
        }
    }
}

private struct DestinationPicker: View {
    @Binding var choice: DestinationChoice
    let suggestedTitle: String
    let allSeries: [Series]

    /// L'utente non ha ancora toccato il campo nome: lo teniamo agganciato
    /// alla query così mentre digita "steins gate" il nome propone lo stesso.
    @State private var nameFollowsSuggestion = true

    /// Solo le serie tv possono ricevere accodamenti — i film hanno 1 episodio
    /// e stop, non ha senso "accodare" a un film.
    private var seriesForAppending: [Series] { allSeries.filter { !$0.isMovie } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill.badge.plus").foregroundStyle(.tint)
                Text("Dove salvare").font(.callout).bold()
            }

            Picker("", selection: $choice.mode) {
                Text("Film").tag(DestinationChoice.Mode.movie)
                Text("Nuova serie").tag(DestinationChoice.Mode.newSeries)
                Text("Accoda a serie").tag(DestinationChoice.Mode.appendTo)
                    .disabled(seriesForAppending.isEmpty)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            HStack(spacing: 10) {
                switch choice.mode {
                case .movie:
                    TextField("Titolo del film",
                              text: Binding(
                                get: {
                                    if nameFollowsSuggestion && choice.newTitle.isEmpty {
                                        return suggestedTitle
                                    }
                                    return choice.newTitle
                                },
                                set: { new in
                                    nameFollowsSuggestion = false
                                    choice.newTitle = new
                                }
                              ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                case .newSeries:
                    TextField("Nome della nuova serie",
                              text: Binding(
                                get: {
                                    if nameFollowsSuggestion && choice.newTitle.isEmpty {
                                        return suggestedTitle
                                    }
                                    return choice.newTitle
                                },
                                set: { new in
                                    nameFollowsSuggestion = false
                                    choice.newTitle = new
                                }
                              ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                case .appendTo:
                    Picker("", selection: Binding(
                        get: { choice.appendSeriesID ?? seriesForAppending.first?.id ?? UUID() },
                        set: { choice.appendSeriesID = $0 }
                    )) {
                        ForEach(seriesForAppending) { s in
                            Text("\(s.title)  ·  \(s.episodeCount) ep.").tag(s.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }

                if choice.mode != .movie {
                    HStack(spacing: 6) {
                        Text("Stagione").foregroundStyle(.secondary).font(.callout)
                        Stepper(value: $choice.season, in: 1...99) {
                            Text("\(choice.season)").monospacedDigit().frame(width: 24, alignment: .leading)
                        }
                        .frame(width: 130)
                    }
                }
            }

            if choice.mode == .appendTo,
               let sid = choice.appendSeriesID ?? seriesForAppending.first?.id,
               let s = seriesForAppending.first(where: { $0.id == sid }) {
                Text(existingSeasonHint(for: s))
                    .font(.caption).foregroundStyle(.secondary)
            } else if choice.mode == .movie {
                Text("Il film comparirà nella sezione “Film” della libreria.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if choice.appendSeriesID == nil, let first = seriesForAppending.first {
                choice.appendSeriesID = first.id
            }
        }
        .onChange(of: choice.appendSeriesID) { _, _ in syncSeasonToTarget() }
        .onChange(of: choice.mode) { _, _ in syncSeasonToTarget() }
    }

    private func syncSeasonToTarget() {
        guard choice.mode == .appendTo,
              let sid = choice.appendSeriesID,
              let s = seriesForAppending.first(where: { $0.id == sid })
        else { return }
        let maxSeason = s.seasons.map(\.number).max() ?? 0
        choice.season = maxSeason + 1
    }

    private func existingSeasonHint(for s: Series) -> String {
        let numbers = s.seasons.map(\.number).sorted()
        if numbers.contains(choice.season) {
            let ep = s.seasons.first { $0.number == choice.season }?.episodes.count ?? 0
            return "La stagione \(choice.season) esiste già con \(ep) episodi. I nuovi verranno accodati."
        }
        return "Verrà creata la stagione \(choice.season) in “\(s.title)”."
    }
}

// MARK: - Prompt interattivo

/// Pannello che compare quando VibraVid attende input. Mostra la domanda,
/// eventuali risultati in forma di lista cliccabile, un campo di risposta e
/// bottoni rapidi.
private struct PromptPanel: View {
    let prompt: VibraVidRunner.PendingPrompt
    @ObservedObject var runner: VibraVidRunner
    @State private var reply: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.tint)
                Text("VibraVid chiede").font(.callout).bold()
                Spacer()
            }
            Text(prompt.question)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let table = prompt.table {
                tableView(table)
            }

            HStack(spacing: 8) {
                TextField("Rispondi (Invio per confermare)", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { sendReply() }

                Button("Invia") { sendReply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)

                ForEach(prompt.quickReplies, id: \.self) { hint in
                    Button(hint) {
                        runner.send(hint == "Invio" ? "" : hint)
                        reply = ""
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.35)))
        .onAppear { focused = true }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        runner.send(text)
        reply = ""
    }

    @ViewBuilder
    private func tableView(_ table: VibraVidRunner.PromptTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Intestazione
            HStack(alignment: .top) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, h in
                    Text(h.uppercased())
                        .font(.caption2).bold()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        Button {
                            if let col = table.indexColumn, col < row.count {
                                runner.send(row[col])
                            } else if !row.isEmpty {
                                // Fallback: la prima colonna è quasi sempre l'indice.
                                runner.send(row[0])
                            }
                        } label: {
                            HStack(alignment: .top) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(rowIndex.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color.primary.opacity(0.04))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clic per inviare “\(row.first ?? "")” come risposta")
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
