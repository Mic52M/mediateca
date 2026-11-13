import Foundation
import SwiftUI

/// Sorgente unica per il ponte con VibraVid: individua l'installazione, legge e
/// riscrive i file di configurazione (`config.toml`, `login.toml`,
/// `domains.json`) e tiene in memoria i dati che l'interfaccia mostra.
///
/// Le scritture sono atomiche, e per i TOML riguardano solo le righe cambiate.
@MainActor
final class VibraVidBridge: ObservableObject {

    // MARK: - Individuazione dell'installazione

    /// Cartella della checkout VibraVid. L'utente può cambiarla in un secondo
    /// momento da Impostazioni, ma il default copre il 100% delle installazioni
    /// standard fatte con `git clone` nella cartella Documenti.
    @Published var installDir: URL = defaultInstallDir() {
        didSet {
            UserDefaults.standard.set(installDir.path, forKey: "vibravidPath")
            reload()
        }
    }

    static func defaultInstallDir() -> URL {
        if let custom = UserDefaults.standard.string(forKey: "vibravidPath"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/VibraVid", isDirectory: true)
    }

    var pythonPath: URL { installDir.appendingPathComponent("venv/bin/python") }
    var entryPoint: URL { installDir.appendingPathComponent("manual.py") }

    // Dalla 1.5 di VibraVid la configurazione è in TOML; i domini restano JSON.
    var configFile: URL { installDir.appendingPathComponent("Conf/config.toml") }
    var domainsFile: URL { installDir.appendingPathComponent("Conf/domains.json") }
    var loginFile: URL { installDir.appendingPathComponent("Conf/login.toml") }

    /// Cartella dei download. Rispetta l'eventuale path assoluto o relativo
    /// scritto in `OUTPUT.root_path` del config.
    var downloadRoot: URL {
        let root = config["OUTPUT"]?["root_path"] as? String ?? "Video"
        if root.hasPrefix("/") { return URL(fileURLWithPath: root, isDirectory: true) }
        return installDir.appendingPathComponent(root, isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath.path)
            && FileManager.default.fileExists(atPath: entryPoint.path)
    }

    // MARK: - Stato pubblicato

    @Published private(set) var providers: [Provider] = []
    @Published var domains: [DomainEntry] = []
    @Published var config: [String: [String: Any]] = [:]
    @Published var login: [String: Any] = [:]
    @Published var loadError: String?

    /// Copia dei valori letti dal file: al salvataggio si riscrivono solo le
    /// chiavi che l'utente ha davvero cambiato.
    private var configSnapshot: [String: [String: Any]] = [:]
    private var loginSnapshot: [String: [String: Any]] = [:]

    struct Provider: Identifiable, Hashable {
        var index: Int
        var name: String
        var category: String        // "anime", "film_serie", "serie"
        var id: Int { index }
        var display: String { name.capitalized }
    }

    /// Rappresentazione editabile di una voce del file domains.json.
    struct DomainEntry: Identifiable, Hashable {
        var id = UUID()
        var key: String             // es. "streamingcommunity"
        var fullURL: String         // es. "https://streamingcommunityz.eu/"
        var lastStatus: Int?        // ultimo HTTP status (informativo)
        var timeChange: String?
    }

    init() {
        reload()
    }

    // MARK: - Caricamento

    func reload() {
        loadError = nil
        loadProviders()
        loadDomains()
        loadConfig()
        loadLogin()
    }

    /// I provider sono le sottocartelle di `VibraVid/services/`: ogni cartella
    /// (esclusi i file speciali) è un servizio, l'indice viene dedotto dal
    /// campo `indice` del suo `__init__.py`. Un fallback ordina in ordine
    /// alfabetico se non riesce a leggere gli indici.
    private func loadProviders() {
        let servicesDir = installDir.appendingPathComponent("VibraVid/services", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: servicesDir.path)
        else { providers = []; return }

        var found: [Provider] = []
        for name in items where !name.hasPrefix("_") && !name.hasPrefix(".") {
            let dir = servicesDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let initFile = dir.appendingPathComponent("__init__.py")
            let text = (try? String(contentsOf: initFile, encoding: .utf8)) ?? ""
            let index = Self.firstInt(in: text, key: "indice") ?? 999
            let category = Self.firstString(in: text, key: "_useFor") ?? "generic"
            found.append(Provider(index: index, name: name, category: category.lowercased()))
        }
        providers = found.sorted { $0.index < $1.index }
    }

    private static func firstInt(in text: String, key: String) -> Int? {
        let pattern = #"\#(key)\s*=\s*(\d+)"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(text[r].split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? "")
    }

    private static func firstString(in text: String, key: String) -> String? {
        let pattern = #"\#(key)\s*=\s*["']([^"']+)["']"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(text[r])
        return match.split(separator: "\"").dropFirst().first.map(String.init)
            ?? match.split(separator: "'").dropFirst().first.map(String.init)
    }

    private func loadDomains() {
        guard let raw = try? Data(contentsOf: domainsFile),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]]
        else { domains = []; return }

        // Ordine deterministico per chiave: senza questo, ogni salvataggio
        // farebbe cambiare posto alle righe della tabella.
        domains = obj.keys.sorted().map { key in
            let v = obj[key] ?? [:]
            return DomainEntry(
                key: key,
                fullURL: v["full_url"] as? String ?? "",
                lastStatus: v["last_status"] as? Int,
                timeChange: v["time_change"] as? String
            )
        }
    }

    private func loadConfig() {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else {
            config = [:]; configSnapshot = [:]; return
        }
        config = TomlLite.parse(text)
        configSnapshot = config
    }

    private func loadLogin() {
        guard let text = try? String(contentsOf: loginFile, encoding: .utf8) else {
            login = [:]; loginSnapshot = [:]; return
        }
        let parsed = TomlLite.parse(text)
        login = parsed
        loginSnapshot = parsed
    }

    // MARK: - Salvataggio

    /// Aggiunge una riga alla tabella dei domini. L'utente digita l'URL e poi
    /// salva. Se il nome è duplicato non facciamo nulla (la voce esiste già e
    /// verrebbe sovrascritta dal save).
    func addDomain(name: String) {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        guard !domains.contains(where: { $0.key == key }) else { return }
        domains.append(DomainEntry(key: key, fullURL: "https://"))
        domains.sort { $0.key < $1.key }
    }

    /// Rimuove una voce sia dalla lista in memoria che dal file al prossimo
    /// save. Serve un save() esplicito per persistere.
    func removeDomain(id: DomainEntry.ID) {
        domains.removeAll { $0.id == id }
        // Rimozione atomica: riscrivo domains.json senza quella chiave.
        var raw: [String: [String: Any]] =
            (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: domainsFile)) ?? Data())
                as? [String: [String: Any]]) ?? [:]
        raw = raw.filter { key, _ in domains.contains(where: { $0.key == key }) }
        writeJSON(raw, to: domainsFile)
    }

    /// Riscrive domains.json dalla tabella, preservando i campi che l'UI non
    /// modifica (cronologia degli stati, scadenza SSL, ecc.).
    func saveDomains() {
        var raw: [String: [String: Any]] =
            (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: domainsFile)) ?? Data())
                as? [String: [String: Any]]) ?? [:]

        for entry in domains {
            var body = raw[entry.key] ?? [:]
            let normalizedURL = entry.fullURL.hasSuffix("/") ? entry.fullURL : entry.fullURL + "/"
            body["full_url"] = normalizedURL
            body["time_change"] = Self.now()
            raw[entry.key] = body
        }
        writeJSON(raw, to: domainsFile)
    }

    func saveConfig() {
        let changed = applyChanges(config, against: configSnapshot, to: configFile)
        if changed { loadConfig() }
    }

    func saveLogin() {
        // `login` è annidato come [sezione: [chiave: valore]]
        var flat: [String: [String: Any]] = [:]
        for (section, body) in login {
            if let dict = body as? [String: Any] { flat[section] = dict }
        }
        let changed = applyChanges(flat, against: loginSnapshot, to: loginFile)
        if changed { loadLogin() }
    }

    /// Scrive nel file TOML solo i valori diversi dallo snapshot, riga per
    /// riga: commenti, array e tutto il resto restano com'erano.
    @discardableResult
    private func applyChanges(_ current: [String: [String: Any]],
                              against snapshot: [String: [String: Any]],
                              to url: URL) -> Bool {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Impossibile leggere \(url.lastPathComponent)."
            return false
        }
        var touched = false
        for (section, body) in current.sorted(by: { $0.key < $1.key }) {
            for (key, value) in body.sorted(by: { $0.key < $1.key }) {
                if let old = snapshot[section]?[key], Self.same(old, value) { continue }
                text = TomlLite.setValue(text, section: section, key: key, value: value)
                touched = true
            }
        }
        guard touched else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            loadError = "Impossibile salvare \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
        return true
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        String(describing: type(of: a)) == String(describing: type(of: b))
            && String(describing: a) == String(describing: b)
    }

    /// Scrittura atomica e con lo stesso stile di indentazione del file
    /// originale (4 spazi), per non generare rumore nei diff git.
    private func writeJSON(_ value: Any, to url: URL) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let indented = data.reindented(fromTwoToFour: true)
            try indented.write(to: url, options: .atomic)
        } catch {
            loadError = "Impossibile salvare \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Europe/Rome")
        return f.string(from: Date())
    }

    // MARK: - Utility di lettura config

    func configBool(_ section: String, _ key: String, default def: Bool = false) -> Bool {
        (config[section]?[key] as? Bool) ?? def
    }

    func configString(_ section: String, _ key: String, default def: String = "") -> String {
        (config[section]?[key] as? String) ?? def
    }

    func configInt(_ section: String, _ key: String, default def: Int = 0) -> Int {
        if let n = config[section]?[key] as? Int { return n }
        if let n = config[section]?[key] as? Double { return Int(n) }
        return def
    }

    func setConfig(_ section: String, _ key: String, _ value: Any) {
        var s = config[section] ?? [:]
        s[key] = value
        config[section] = s
    }
}

// MARK: - Piccolo aiuto per l'indentazione dei JSON

private extension Data {
    /// JSONSerialization indenta con 2 spazi; VibraVid ha i suoi file a 4.
    /// Riformattare mantiene i diff git puliti.
    func reindented(fromTwoToFour: Bool) -> Data {
        guard fromTwoToFour, var s = String(data: self, encoding: .utf8) else { return self }
        var out = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var i = 0
            while i < line.count, line[line.index(line.startIndex, offsetBy: i)] == " " { i += 1 }
            let spaces = String(repeating: " ", count: i * 2)
            out += spaces + line.dropFirst(i) + "\n"
        }
        if out.hasSuffix("\n") { out.removeLast() }
        s = out
        return Data(s.utf8)
    }
}
