import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pannello Impostazioni: tre schede, una per file di configurazione VibraVid.
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bridge: VibraVidBridge

    enum Tab: String, CaseIterable, Identifiable {
        case domains = "Domini"
        case download = "Download"
        case account = "Account"
        case install = "Percorso VibraVid"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .domains

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
            .padding(24)
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24).padding(.top, 14)

            ScrollView {
                Group {
                    switch tab {
                    case .domains:  DomainsTable(bridge: bridge)
                    case .download: DownloadPreferences(bridge: bridge)
                    case .account:  LoginEditor(bridge: bridge)
                    case .install:  InstallLocation(bridge: bridge)
                    }
                }
                .padding(24)
            }
        }
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

    var filtered: [VibraVidBridge.DomainEntry.ID] {
        let q = filter.lowercased()
        return bridge.domains
            .filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.fullURL.lowercased().contains(q) }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Filtra per nome sito o URL", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Button("Salva modifiche") { bridge.saveDomains() }
                    .buttonStyle(.borderedProminent)
            }

            Text("Modifica dominio e URL completo quando un sito cambia indirizzo. "
               + "Le modifiche entrano in vigore al prossimo avvio di un download.")
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

                TableColumn("Ultimo status") { entry in
                    if let s = entry.wrappedValue.lastStatus {
                        Text("\(s)")
                            .foregroundStyle(s == 200 ? .green : .orange)
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 100)
            }
            .frame(minHeight: 460)
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
