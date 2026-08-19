import AppKit
import SwiftUI

/// Pannello "Scarica" come percorso lineare: cerchi, scegli, scarica, finito.
/// Il terminale non è più protagonista: vive in una sezione richiudibile in
/// fondo, chiusa di default.
struct DownloadScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: VibraVidRunner
    @ObservedObject var bridge: VibraVidBridge

    enum Mode: String, CaseIterable, Identifiable {
        case search = "Cerca"
        case url = "Da link"
        var id: String { rawValue }
    }

    /// Fase corrente, derivata dallo stato del runner: la UI non tiene stato
    /// duplicato, così non può mai andare fuori sincrono col processo.
    enum Stage {
        case form          // niente in corso: si compila la ricerca
        case question      // VibraVid ha chiesto qualcosa
        case working       // download in corso
        case finished      // terminato (bene o male)
    }

    @State private var mode: Mode = .search
    @State private var showConsole = false

    init(runner: VibraVidRunner, bridge: VibraVidBridge) {
        self.runner = runner
        self.bridge = bridge
    }

    private var stage: Stage {
        if runner.pendingPrompt != nil { return .question }
        switch runner.phase {
        case .idle:     return .form
        case .running:  return .working
        default:        return .finished
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)

            if !bridge.isInstalled {
                installationMissing
            } else {
                stageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                consoleSection
            }
        }
        .themedBackground()
        .navigationTitle("Scarica")
    }

    // MARK: - Header con indicatore di passo

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Scarica")
                    .font(.title2).bold()
                    .foregroundStyle(Theme.text)
                Spacer()
                if stage == .working || stage == .question {
                    Button("Annulla") { runner.cancel() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }

            if bridge.isInstalled {
                StepIndicator(stage: stage)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: - Contenuto per fase

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .form:
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)

                    switch mode {
                    case .search: SearchForm(runner: runner, bridge: bridge)
                    case .url:    DirectURLForm(runner: runner)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
            }

        case .question:
            if let prompt = runner.pendingPrompt {
                QuestionPanel(prompt: prompt, runner: runner)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.lg)
            }

        case .working:
            WorkingPanel(runner: runner)
                .padding(.horizontal, Theme.Spacing.xl)

        case .finished:
            FinishedPanel(runner: runner) {
                runner.reset()
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
    }

    // MARK: - Console richiudibile

    private var consoleSection: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showConsole.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showConsole ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Dettagli tecnici")
                            .font(.caption)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if !runner.downloadedFiles.isEmpty {
                    Label("\(runner.downloadedFiles.count) file",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }
                if showConsole {
                    Button("Svuota") { runner.clearLog() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)

            if showConsole {
                LogConsoleView(
                    text: runner.log.isEmpty ? "Nessun output." : runner.log,
                    dimmed: runner.log.isEmpty
                )
                .frame(height: 240)
            }
        }
        .background(Theme.surface.opacity(0.5))
    }

    // MARK: - VibraVid assente

    private var installationMissing: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.danger)
            Text("VibraVid non trovato")
                .font(.title3).bold()
                .foregroundStyle(Theme.text)
            Text("Cerco un'installazione in \(bridge.installDir.path).")
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Apri Impostazioni") { model.selection = .settings }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Indicatore dei passi

private struct StepIndicator: View {
    let stage: DownloadScreen.Stage

    private var steps: [(String, Bool, Bool)] {
        // (titolo, completato, attivo)
        switch stage {
        case .form:
            return [("Cerca", false, true), ("Scegli", false, false), ("Scarica", false, false)]
        case .question:
            return [("Cerca", true, false), ("Scegli", false, true), ("Scarica", false, false)]
        case .working:
            return [("Cerca", true, false), ("Scegli", true, false), ("Scarica", false, true)]
        case .finished:
            return [("Cerca", true, false), ("Scegli", true, false), ("Scarica", true, false)]
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(step.1 ? Theme.accent
                                  : (step.2 ? Theme.accentSoft : Color.white.opacity(0.06)))
                            .frame(width: 22, height: 22)
                        if step.1 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                        } else {
                            Text("\(index + 1)")
                                .font(.caption2).bold()
                                .foregroundStyle(step.2 ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    Text(step.0)
                        .font(.caption).bold()
                        .foregroundStyle(step.2 ? Theme.text
                                         : (step.1 ? Theme.textSecondary : Theme.textTertiary))
                }

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(step.1 ? Theme.accent.opacity(0.5) : Color.white.opacity(0.08))
                        .frame(width: 28, height: 1.5)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Passo 1: ricerca

private struct SearchForm: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: VibraVidRunner
    @ObservedObject var bridge: VibraVidBridge

    @State private var query: String = ""
    @State private var providerID: Int = 0
    @State private var trackPreset: String = ""
    @State private var target = DestinationChoice()

    private let presets: [(key: String, label: String)] = [
        ("",   "Come da impostazioni"),
        ("2",  "Doppiaggio italiano"),
        ("6",  "Originale + sottotitoli italiani"),
        ("10", "Italiano: audio + sottotitoli"),
        ("3",  "Doppiaggio inglese"),
        ("5",  "Solo lingua originale"),
        ("12", "Tutte le lingue disponibili"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            field("Cosa vuoi guardare") {
                TextField("Titolo del film o della serie", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
                    .frame(maxWidth: 480)
                    .onSubmit { start() }
            }

            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                field("Dove cercare") {
                    Picker("", selection: $providerID) {
                        ForEach(bridge.providers) { p in
                            Text(p.display).tag(p.index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                field("Lingua preferita") {
                    Picker("", selection: $trackPreset) {
                        ForEach(presets, id: \.key) { p in Text(p.label).tag(p.key) }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
            }

            field("Dove salvarlo in libreria") {
                DestinationPicker(choice: $target,
                                  suggestedTitle: query,
                                  allSeries: model.data.series)
            }

            Button {
                start()
            } label: {
                Label("Cerca", systemImage: "magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(query.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(label.uppercased())
                .font(.caption2).bold().tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func start() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        runner.pendingTarget = target.resolve(suggestedTitle: q)
        let name = bridge.providers.first { $0.index == providerID }?.name ?? "\(providerID)"
        runner.searchAndDownload(query: q, siteName: name,
                                 trackPresetKey: trackPreset.isEmpty ? nil : trackPreset)
    }
}

// MARK: - Passo 2: la domanda di VibraVid

private struct QuestionPanel: View {
    let prompt: VibraVidRunner.PendingPrompt
    @ObservedObject var runner: VibraVidRunner
    @State private var reply: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(friendlyQuestion)
                .font(.title3).bold()
                .foregroundStyle(Theme.text)

            if let table = prompt.table {
                ResultList(table: table) { value in
                    runner.send(value)
                    reply = ""
                }
                // maxHeight infinito: il pannello prende tutto lo spazio
                // disponibile, era questo il motivo per cui prima si vedeva
                // sì e no una riga.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            manualAnswer
        }
        .frame(maxHeight: .infinity)
    }

    /// Traduce le domande note di VibraVid in italiano comprensibile.
    private var friendlyQuestion: String {
        let q = prompt.question.lowercased()
        if q.contains("media index") || q.contains("insert index") {
            return "Quale vuoi scaricare?"
        }
        if q.contains("season") { return "Quale stagione?" }
        if q.contains("episode") { return "Quali episodi?" }
        return prompt.question
    }

    private var manualAnswer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Oppure scrivi: 1  ·  1-5  ·  *  per tutti",
                          text: $reply)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
                    .focused($focused)
                    .onSubmit { send(reply) }
                    .frame(maxWidth: 340)

                Button("Invia") { send(reply) }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)

                if prompt.table != nil {
                    Button("Scarica tutti") { send("*") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                Spacer()
            }

            Text("Suggerimento: puoi anche cliccare direttamente una riga qui sopra.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .onAppear { focused = true }
    }

    private func send(_ text: String) {
        runner.send(text.trimmingCharacters(in: .whitespaces))
        reply = ""
    }
}

/// Lista dei risultati: rende leggibile la tabella che VibraVid stampa,
/// riconoscendo semanticamente le colonne (indice, nome, il resto come tag).
private struct ResultList: View {
    let table: VibraVidRunner.PromptTable
    let onPick: (String) -> Void

    private var indexCol: Int { table.indexColumn ?? 0 }

    private var nameCol: Int? {
        table.headers.firstIndex { h in
            let l = h.lowercased()
            return l.contains("name") || l.contains("title") || l.contains("nome")
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { i, row in
                    ResultRow(
                        index: value(row, indexCol),
                        title: nameCol.map { value(row, $0) } ?? value(row, 0),
                        tags: tags(for: row),
                        alternate: i.isMultiple(of: 2)
                    ) {
                        onPick(value(row, indexCol))
                    }
                    if i < table.rows.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func value(_ row: [String], _ col: Int) -> String {
        col < row.count ? row[col] : ""
    }

    /// Tutte le colonne che non sono indice o nome diventano etichette.
    private func tags(for row: [String]) -> [String] {
        var out: [String] = []
        for (i, cell) in row.enumerated() {
            guard i != indexCol, i != nameCol else { continue }
            let v = cell.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty && v != "-" && v != "N/A" { out.append(v) }
        }
        return out
    }
}

private struct ResultRow: View {
    let index: String
    let title: String
    let tags: [String]
    let alternate: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Text(index)
                    .font(.callout).bold().monospacedDigit()
                    .foregroundStyle(hovering ? .black.opacity(0.85) : Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(hovering ? Theme.accent : Theme.accentSoft)
                    )

                Text(title)
                    .font(.body).bold()
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.md)

                HStack(spacing: 6) {
                    ForEach(Array(tags.prefix(4).enumerated()), id: \.offset) { _, tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.05)
                        : (alternate ? Color.clear : Color.white.opacity(0.02)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Passo 3: download in corso

private struct WorkingPanel: View {
    @ObservedObject var runner: VibraVidRunner

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Download in corso")
                        .font(.title3).bold()
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if let p = runner.progress {
                        Text("\(Int(p * 100))%")
                            .font(.title3).bold().monospacedDigit()
                            .foregroundStyle(Theme.accent)
                    }
                }

                if let p = runner.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Theme.accent)
                                .frame(width: geo.size.width * p)
                        }
                    }
                    .frame(height: 6)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }

                if !runner.statusLine.isEmpty {
                    Text(runner.statusLine)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            .card()

            if !runner.downloadedFiles.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("GIÀ SCARICATI")
                        .font(.caption2).bold().tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(runner.downloadedFiles, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.success)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.bottom, Theme.Spacing.xl)
    }
}

// MARK: - Passo 4: fine

private struct FinishedPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: VibraVidRunner
    let onNewSearch: () -> Void

    private var success: Bool {
        if case .done(let code) = runner.phase { return code == 0 }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(success ? Theme.success : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.title3).bold()
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .card()

            if !runner.downloadedFiles.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("AGGIUNTI ALLA LIBRERIA")
                        .font(.caption2).bold().tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(runner.downloadedFiles, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "film")
                            .font(.callout)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.md) {
                Button("Nuova ricerca") { onNewSearch() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Vai alla libreria") { model.selection = .home }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()
        }
        .padding(.bottom, Theme.Spacing.xl)
    }

    private var headline: String {
        switch runner.phase {
        case .cancelled: return "Annullato"
        case .failed:    return "Non è riuscito"
        case .done(let c): return c == 0 ? "Fatto!" : "Terminato con errori"
        default: return ""
        }
    }

    private var detail: String {
        if case .failed(let msg) = runner.phase { return msg }
        if runner.downloadedFiles.isEmpty {
            return "Nessun file nuovo. Apri i dettagli tecnici per capire cosa è successo."
        }
        let n = runner.downloadedFiles.count
        return n == 1
            ? "1 file scaricato e aggiunto alla libreria."
            : "\(n) file scaricati e aggiunti alla libreria."
    }
}

// MARK: - Scelta destinazione

struct DestinationChoice: Equatable {
    enum Mode: String, CaseIterable { case movie, newSeries, appendTo }
    var mode: Mode = .newSeries
    var newTitle: String = ""
    var appendSeriesID: UUID?
    var season: Int = 1

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

    @State private var nameFollowsSuggestion = true

    private var seriesForAppending: [Series] { allSeries.filter { !$0.isMovie } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Picker("", selection: $choice.mode) {
                Text("Film").tag(DestinationChoice.Mode.movie)
                Text("Nuova serie").tag(DestinationChoice.Mode.newSeries)
                Text("Serie esistente").tag(DestinationChoice.Mode.appendTo)
                    .disabled(seriesForAppending.isEmpty)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)

            HStack(spacing: Theme.Spacing.md) {
                switch choice.mode {
                case .movie, .newSeries:
                    TextField(choice.mode == .movie ? "Titolo del film" : "Nome della serie",
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
                        .frame(maxWidth: 300)
                case .appendTo:
                    Picker("", selection: Binding(
                        get: { choice.appendSeriesID ?? seriesForAppending.first?.id ?? UUID() },
                        set: { choice.appendSeriesID = $0 }
                    )) {
                        ForEach(seriesForAppending) { s in
                            Text(s.title).tag(s.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }

                if choice.mode != .movie {
                    HStack(spacing: 6) {
                        Text("Stagione").foregroundStyle(Theme.textSecondary).font(.callout)
                        Stepper(value: $choice.season, in: 1...99) {
                            Text("\(choice.season)").monospacedDigit()
                                .frame(width: 24, alignment: .leading)
                        }
                        .frame(width: 120)
                    }
                }
                Spacer()
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .onAppear {
            if choice.appendSeriesID == nil, let first = seriesForAppending.first {
                choice.appendSeriesID = first.id
            }
        }
        .onChange(of: choice.appendSeriesID) { _, _ in syncSeason() }
        .onChange(of: choice.mode) { _, _ in syncSeason() }
    }

    private func syncSeason() {
        guard choice.mode == .appendTo,
              let sid = choice.appendSeriesID,
              let s = seriesForAppending.first(where: { $0.id == sid })
        else { return }
        choice.season = (s.seasons.map(\.number).max() ?? 0) + 1
    }

    private var hint: String {
        switch choice.mode {
        case .movie:
            return "Finirà nella sezione Film della libreria."
        case .newSeries:
            return "Verrà creata una nuova serie con la stagione \(choice.season)."
        case .appendTo:
            guard let sid = choice.appendSeriesID,
                  let s = seriesForAppending.first(where: { $0.id == sid })
            else { return "" }
            if s.seasons.contains(where: { $0.number == choice.season }) {
                let n = s.seasons.first { $0.number == choice.season }?.episodes.count ?? 0
                return "La stagione \(choice.season) esiste già con \(n) episodi: i nuovi si accodano."
            }
            return "Verrà creata la stagione \(choice.season) in “\(s.title)”."
        }
    }
}

// MARK: - Download da link diretto

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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("LINK DEL VIDEO")
                    .font(.caption2).bold().tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
                TextField("https://…/video.m3u8", text: $url)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.border, lineWidth: 0.5))
                    .frame(maxWidth: 560)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("DOVE SALVARLO")
                    .font(.caption2).bold().tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
                DestinationPicker(choice: $target,
                                  suggestedTitle: suggestedTitle,
                                  allSeries: model.data.series)
            }

            DisclosureGroup("Opzioni avanzate") {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    labeled("Nome file") {
                        TextField("automatico", text: $output)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("Header HTTP") {
                        TextEditor(text: $headerText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Theme.border))
                    }
                    labeled("Sistema DRM") {
                        Picker("", selection: $drm) {
                            ForEach(["auto", "widevine", "playready"], id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                    labeled("URL licenza") {
                        TextField("opzionale", text: $licenseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("Header licenza") {
                        TextEditor(text: $licenseHeaderText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Theme.border))
                    }
                    labeled("Chiavi KID:KEY") {
                        TextEditor(text: $keyText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Theme.border))
                    }
                }
                .padding(.top, Theme.Spacing.sm)
                .frame(maxWidth: 560)
            }
            .tint(Theme.accent)

            Button {
                start()
            } label: {
                Label("Scarica", systemImage: "arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(url.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
    }

    private func labeled<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text(label)
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(Theme.textSecondary)
                .font(.callout)
            content()
        }
    }

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

// MARK: - Console (nascosta di default)

/// SwiftUI `Text` rirenderizza tutta la stringa a ogni aggiornamento: con log
/// da decine di migliaia di caratteri manda in stallo il main thread. Un
/// NSTextView riusa il proprio layout manager ed è progettato per questo.
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
        text.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        text.textContainerInset = NSSize(width: 16, height: 12)
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
        let color: NSColor = dimmed
            ? NSColor.white.withAlphaComponent(0.35)
            : NSColor.white.withAlphaComponent(0.75)
        let current = storage.string

        guard current != text else {
            if view.textColor != color { view.textColor = color }
            return
        }

        let stickToBottom: Bool = {
            guard let clip = scroll.contentView as NSClipView? else { return true }
            return (clip.documentVisibleRect.maxY + 40) >= view.frame.height
        }()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        // Se il testo nuovo è un'estensione del precedente appendiamo solo la
        // differenza: molto più veloce che riassegnare tutta la stringa.
        if text.hasPrefix(current) {
            let appended = String(text.dropFirst(current.count))
            if !appended.isEmpty {
                storage.append(NSAttributedString(string: appended, attributes: attrs))
            }
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        view.textColor = color

        if stickToBottom { view.scrollToEndOfDocument(nil) }
    }
}
