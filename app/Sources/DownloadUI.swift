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
            Divider()

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

                Divider()
                if let prompt = runner.pendingPrompt {
                    PromptPanel(prompt: prompt, runner: runner)
                        .padding(.horizontal, 24).padding(.top, 12)
                    Divider().padding(.top, 12)
                }
                logConsole
            }
        }
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

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "In attesa di comandi…" : runner.log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(runner.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: runner.log) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Ricerca

private struct SearchForm: View {
    @ObservedObject var runner: VibraVidRunner
    @ObservedObject var bridge: VibraVidBridge

    @State private var query: String = ""
    @State private var providerID: Int = 0
    @State private var useGlobal = false
    @State private var category: Int = 0     // 0 = tutte
    @State private var trackPreset: String = ""

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
    @ObservedObject var runner: VibraVidRunner

    @State private var url = ""
    @State private var output = ""
    @State private var headerText = ""
    @State private var licenseURL = ""
    @State private var licenseHeaderText = ""
    @State private var keyText = ""
    @State private var drm = "auto"

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

    private func start() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
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
