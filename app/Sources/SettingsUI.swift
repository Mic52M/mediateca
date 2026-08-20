import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pannello Impostazioni: tre schede, una per file di configurazione VibraVid.
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bridge: VibraVidBridge

    enum Tab: String, CaseIterable, Identifiable {
        case update = "Aggiornamento"
        case domains = "Domini"
        case download = "Download"
        case account = "Account"
        case install = "Percorso VibraVid"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .update
    @StateObject private var updater = Updater()

    init(bridge: VibraVidBridge) { self.bridge = bridge }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gearshape").font(.system(size: 24)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Impostazioni").font(.title2).bold()
                    Text("Modifica quello che prima si toccava dai file JSON di VibraVid.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    bridge.reload()
                } label: { Label("Ricarica dai file", systemImage: "arrow.clockwise") }
                    .controlSize(.large)
            }
            .padding(Theme.Spacing.xl)
            Divider().overlay(Theme.border)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.xl).padding(.top, Theme.Spacing.md)

            ScrollView {
                Group {
                    switch tab {
                    case .update:   UpdatePanel(updater: updater)
                    case .domains:  DomainsTable(bridge: bridge)
                    case .download: DownloadPreferences(bridge: bridge)
                    case .account:  LoginEditor(bridge: bridge)
                    case .install:  InstallLocation(bridge: bridge)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
            .onAppear {
                // Al primo ingresso in Impostazioni facciamo una verifica
                // silenziosa così l'utente sa subito se c'è un update.
                if updater.phase == .idle, updater.isConfigured {
                    updater.check()
                }
            }
        }
        .themedBackground()
        .navigationTitle("Impostazioni")
        .alert("Configurazione", isPresented: Binding(
            get: { bridge.loadError != nil },
            set: { if !$0 { bridge.loadError = nil } }
        )) {
            Button("OK", role: .cancel) { bridge.loadError = nil }
        } message: {
            Text(bridge.loadError ?? "")
        }
    }
}

// MARK: - Domini

private struct DomainsTable: View {
    @ObservedObject var bridge: VibraVidBridge
    @State private var filter = ""
    @State private var showAddSheet = false
    @State private var pendingDeleteID: VibraVidBridge.DomainEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                TextField("Filtra per nome sito o URL", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Aggiungi sito", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))

                Button("Salva modifiche") { bridge.saveDomains() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }

            if bridge.domains.isEmpty {
                emptyState
            } else {
                Text("Modifica dominio e URL completo quando un sito cambia indirizzo. "
                   + "Le modifiche entrano in vigore al prossimo download.")
                    .font(.callout).foregroundStyle(.secondary)

                Table($bridge.domains) {
                    TableColumn("Sito") { entry in
                        Text(entry.wrappedValue.key)
                            .font(.callout).bold()
                    }
                    .width(min: 140, ideal: 170)

                    TableColumn("Dominio") { entry in
                        TextField("es. eu", text: entry.domain)
                            .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("URL completo") { entry in
                        TextField("https://sito.tld/", text: entry.fullURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    TableColumn("Stato") { entry in
                        if let s = entry.wrappedValue.lastStatus {
                            Text("\(s)")
                                .foregroundStyle(s == 200 ? .green : .orange)
                                .monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn("") { entry in
                        Button {
                            pendingDeleteID = entry.wrappedValue.id
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                        .help("Rimuovi questo sito")
                    }
                    .width(30)
                }
                .frame(minHeight: 420)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDomainSheet(bridge: bridge)
        }
        .alert("Rimuovere questo sito?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("Rimuovi", role: .destructive) {
                if let id = pendingDeleteID { bridge.removeDomain(id: id) }
                pendingDeleteID = nil
            }
            Button("Annulla", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("La voce sparisce da questa tabella e dal file di configurazione.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Nessun sito configurato")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text("VibraVid non ha ancora scaricato l'elenco dei siti. "
               + "Fai un primo download da “Scarica” e la lista si popola da sola, "
               + "oppure aggiungi manualmente un sito qui.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                showAddSheet = true
            } label: {
                Label("Aggiungi il primo sito", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct AddDomainSheet: View {
    @ObservedObject var bridge: VibraVidBridge
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    /// Suggerimenti: i siti supportati dai provider di VibraVid che non
    /// sono ancora nella lista dei domini. Chi non sa cosa scrivere può
    /// prenderne uno con un click.
    private var suggestions: [String] {
        let existing = Set(bridge.domains.map(\.key))
        return bridge.providers
            .map(\.name)
            .filter { !existing.contains($0.lowercased()) }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Aggiungi un sito")
                .font(.title3).bold()
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("NOME DEL SITO")
                    .font(.caption2).bold().tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
                TextField("es. streamingcommunity", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(confirm)
                Text("Deve corrispondere al nome di un provider di VibraVid.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("SITI DISPONIBILI")
                        .font(.caption2).bold().tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                    ScrollView {
                        FlowLayout(spacing: 6) {
                            ForEach(suggestions, id: \.self) { s in
                                Button {
                                    name = s
                                } label: {
                                    Text(s)
                                        .font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Theme.surfaceElevated, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                                        .foregroundStyle(Theme.text)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            HStack {
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Spacer()
                Button("Aggiungi") { confirm() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        bridge.addDomain(name: trimmed)
        dismiss()
    }
}

/// Layout tag "a flusso" (wrap alla fine della riga). SwiftUI non ne ha
/// uno built-in su macOS 14, quindi ci pensiamo noi.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Preferenze download

private struct DownloadPreferences: View {
    @ObservedObject var bridge: VibraVidBridge
    @State private var showFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section("Output") {
                labeled("Cartella base") {
                    HStack {
                        Text(bridge.downloadRoot.path)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Cambia…") { showFolderPicker = true }
                        Button("Apri") {
                            NSWorkspace.shared.open(bridge.downloadRoot)
                        }
                    }
                }
                textField("Sottocartella film",  section: "OUTPUT", key: "movie_folder_name")
                textField("Sottocartella serie", section: "OUTPUT", key: "serie_folder_name")
                textField("Sottocartella anime", section: "OUTPUT", key: "anime_folder_name")
            }

            Section("Selezione tracce di default") {
                textField("Video",       section: "DOWNLOAD", key: "select_video",
                          hint: "es. best  ·  1080p  ·  720p")
                textField("Audio",       section: "DOWNLOAD", key: "select_audio",
                          hint: "es. ita|it  ·  eng")
                textField("Sottotitoli", section: "DOWNLOAD", key: "select_subtitle",
                          hint: "es. ita|eng|it|en")
            }

            Section("Formato di uscita") {
                labeled("Estensione contenitore") {
                    Picker("", selection: extBinding()) {
                        ForEach(["mkv", "mp4"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                }
                labeled("Thread di download") {
                    Stepper(value: intBinding("DOWNLOAD", "thread_count"), in: 1...32) {
                        Text("\(bridge.configInt("DOWNLOAD", "thread_count", default: 8))")
                            .monospacedDigit().frame(width: 32, alignment: .leading)
                    }.frame(width: 180)
                }
                Toggle("Download concorrente", isOn: boolBinding("DOWNLOAD", "concurrent_download"))
                Toggle("Selezione automatica quando c'è un unico risultato",
                       isOn: boolBinding("DOWNLOAD", "auto_select"))
                Toggle("Pulisci cartella tmp a fine download",
                       isOn: boolBinding("DOWNLOAD", "cleanup_tmp_folder"))
            }

            Section("Rete") {
                Toggle("Usa proxy configurato", isOn: boolBinding("REQUESTS", "use_proxy"))
                labeled("Timeout (s)") {
                    Stepper(value: intBinding("REQUESTS", "timeout"), in: 5...120) {
                        Text("\(bridge.configInt("REQUESTS", "timeout", default: 20))")
                            .monospacedDigit().frame(width: 32, alignment: .leading)
                    }.frame(width: 180)
                }
            }

            HStack {
                Spacer()
                Button("Salva impostazioni") { bridge.saveConfig() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // Se la cartella scelta sta dentro l'installazione VibraVid la
            // salviamo come path relativo, così il config resta portabile.
            let inside = url.path.hasPrefix(bridge.installDir.path)
            let value = inside
                ? String(url.path.dropFirst(bridge.installDir.path.count + 1))
                : url.path
            bridge.setConfig("OUTPUT", "root_path", value)
            bridge.saveConfig()
        }
    }

    // MARK: helper

    @ViewBuilder
    private func Section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).frame(width: 220, alignment: .leading).foregroundStyle(.secondary)
            content()
            Spacer()
        }
    }

    private func textField(_ label: String, section: String, key: String, hint: String = "") -> some View {
        labeled(label) {
            TextField(hint, text: Binding(
                get: { bridge.configString(section, key) },
                set: { bridge.setConfig(section, key, $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
        }
    }

    private func boolBinding(_ s: String, _ k: String) -> Binding<Bool> {
        Binding(get: { bridge.configBool(s, k) },
                set: { bridge.setConfig(s, k, $0) })
    }

    private func intBinding(_ s: String, _ k: String) -> Binding<Int> {
        Binding(get: { bridge.configInt(s, k, default: 0) },
                set: { bridge.setConfig(s, k, $0) })
    }

    private func extBinding() -> Binding<String> {
        Binding(
            get: { bridge.configString("PROCESS", "extension", default: "mkv") },
            set: { bridge.setConfig("PROCESS", "extension", $0) }
        )
    }
}

// MARK: - Account

private struct LoginEditor: View {
    @ObservedObject var bridge: VibraVidBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Credenziali e token per i provider che li richiedono. "
               + "I valori sono salvati in `Conf/login.json` di VibraVid, in chiaro.")
                .font(.callout).foregroundStyle(.secondary)

            group("Provider generici") {
                secure("TMDB (API key)", path: ["Provider", "tmdb"])
            }
            group("Crunchyroll") {
                secure("device_id", path: ["crunchyroll", "device_id"])
                secure("etp_rt",    path: ["crunchyroll", "etp_rt"])
            }
            group("Tubi") {
                plain("Email",    path: ["tubi", "email"])
                secure("Password", path: ["tubi", "password"])
            }
            group("Mediaset Infinity") {
                secure("adminBeToken", path: ["mediasetinfinity", "adminBeToken"])
            }
            group("Discovery+") {
                secure("st (session token)", path: ["discoveryplus", "st"])
            }

            HStack {
                Spacer()
                Button("Salva credenziali") { bridge.saveLogin() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func plain(_ label: String, path: [String]) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 220, alignment: .leading).foregroundStyle(.secondary)
            TextField("", text: binding(path))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        }
    }

    private func secure(_ label: String, path: [String]) -> some View {
        SecureRow(label: label, text: binding(path))
    }

    private func binding(_ path: [String]) -> Binding<String> {
        Binding(
            get: { getIn(bridge.login, path) as? String ?? "" },
            set: { new in bridge.login = setIn(bridge.login, path, new) }
        )
    }

    private func getIn(_ dict: [String: Any], _ path: [String]) -> Any? {
        var node: Any = dict
        for k in path {
            guard let d = node as? [String: Any], let n = d[k] else { return nil }
            node = n
        }
        return node
    }

    private func setIn(_ dict: [String: Any], _ path: [String], _ value: String) -> [String: Any] {
        guard let key = path.first else { return dict }
        var copy = dict
        if path.count == 1 {
            copy[key] = value
        } else {
            let sub = (copy[key] as? [String: Any]) ?? [:]
            copy[key] = setIn(sub, Array(path.dropFirst()), value)
        }
        return copy
    }
}

/// Campo password con toggle di visibilità. Uso: le credenziali dei provider
/// finiscono su disco in chiaro comunque (VibraVid le vuole così), ma vederle
/// solo su richiesta evita che restino sullo schermo per errore.
private struct SecureRow: View {
    let label: String
    @Binding var text: String
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 220, alignment: .leading).foregroundStyle(.secondary)
            Group {
                if reveal {
                    TextField("", text: $text).textFieldStyle(.roundedBorder)
                } else {
                    SecureField("", text: $text).textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 360)

            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(reveal ? "Nascondi" : "Mostra")
        }
    }
}

// MARK: - Percorso installazione

private struct InstallLocation: View {
    @ObservedObject var bridge: VibraVidBridge
    @State private var picker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Percorso della checkout VibraVid").font(.headline)
            HStack {
                Text(bridge.installDir.path)
                    .textSelection(.enabled)
                    .font(.callout)
                Spacer()
                Button("Cambia…") { picker = true }
                Button("Apri") { NSWorkspace.shared.open(bridge.installDir) }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Image(systemName: bridge.isInstalled ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(bridge.isInstalled ? .green : .orange)
                Text(bridge.isInstalled
                     ? "Installazione trovata (python + manual.py)."
                     : "Installazione non trovata. Controlla il percorso.")
                    .foregroundStyle(.secondary)
            }

            Text("Mediateca lancia VibraVid usando l'interprete `venv/bin/python` "
               + "e il file `manual.py` di questa cartella.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { bridge.installDir = url }
        }
    }
}

// MARK: - Pannello Aggiornamento

private struct UpdatePanel: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            header
            statusCard

            if !updater.log.isEmpty {
                DisclosureGroup("Dettagli tecnici") {
                    ScrollView {
                        Text(updater.log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.md)
                    }
                    .frame(maxHeight: 240)
                    .background(Theme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .tint(Theme.accent)
            }
        }
    }

    // MARK: header e status

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mantieni Mediateca aggiornata")
                    .font(.title3).bold()
                    .foregroundStyle(Theme.text)
                Text("Le novità arrivano direttamente dalla repository su GitHub.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            switch updater.phase {
            case .idle:
                content(icon: "questionmark.circle",
                        color: Theme.textSecondary,
                        title: "Non ho ancora controllato",
                        detail: "Clicca “Verifica aggiornamenti” per vedere se c'è una nuova versione.")
                actions {
                    Button("Verifica aggiornamenti") { updater.check() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!updater.isConfigured)
                }

            case .checking:
                content(icon: "arrow.triangle.2.circlepath",
                        color: Theme.accent,
                        title: "Sto controllando…",
                        detail: "Interrogo GitHub per vedere se ci sono commit nuovi.")

            case .upToDate(let sha, let when):
                content(icon: "checkmark.seal.fill",
                        color: Theme.success,
                        title: "Sei aggiornata",
                        detail: "Versione \(sha) · installata \(when).")
                actions {
                    Button("Ricontrolla") { updater.check() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }

            case .updateAvailable(let commits, let sha, let message):
                content(icon: "sparkles",
                        color: Theme.accent,
                        title: commits == 1
                            ? "Nuova versione disponibile"
                            : "\(commits) aggiornamenti disponibili",
                        detail: "\(sha) — “\(message)”")
                actions {
                    Button {
                        updater.installUpdate()
                    } label: {
                        Label("Aggiorna adesso", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Ricontrolla") { updater.check() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }

            case .updating(let progress):
                content(icon: "arrow.triangle.2.circlepath",
                        color: Theme.accent,
                        title: "Aggiornamento in corso",
                        detail: progress)
                HStack { ProgressView().controlSize(.small); Spacer() }

            case .ready:
                content(icon: "checkmark.seal.fill",
                        color: Theme.success,
                        title: "Aggiornamento pronto",
                        detail: "Serve un riavvio per attivarlo. Ci vogliono due secondi.")
                actions {
                    Button {
                        updater.restart()
                    } label: {
                        Label("Riavvia Mediateca", systemImage: "power")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

            case .failed(let msg):
                content(icon: "exclamationmark.triangle.fill",
                        color: Theme.danger,
                        title: "Aggiornamento non riuscito",
                        detail: msg)
                actions {
                    Button("Riprova") { updater.check() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
    }

    private func content(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            content()
            Spacer()
        }
    }
}
