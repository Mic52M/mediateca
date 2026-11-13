import Foundation

/// Lettura e scrittura minimale di file TOML, quanto basta per i file di
/// configurazione di VibraVid (`config.toml`, `login.toml`).
///
/// Non è un parser completo. Legge solo i valori scalari (stringhe, booleani,
/// numeri); array, tabelle inline e stringhe multilinea vengono saltati. In
/// scrittura sostituisce **solo la riga** della chiave interessata e lascia
/// intatto tutto il resto (commenti, array, ordine), così i file restano
/// leggibili e i diff git piccoli.
enum TomlLite {

    // MARK: - Lettura

    /// Restituisce `[sezione: [chiave: valore]]`. Le chiavi prima della prima
    /// intestazione stanno nella sezione `""`. `[A.b]` diventa la sezione `"A.b"`.
    static func parse(_ text: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        var section = ""
        var skipUntil: String?          // chiusura attesa di un valore multilinea

        for rawLine in lines(of: text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let closer = skipUntil {
                if line.contains(closer) { skipUntil = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), !line.hasPrefix("[["), let end = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<end])
                    .trimmingCharacters(in: .whitespaces)
                if result[section] == nil { result[section] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            // Valori che non leggiamo: se proseguono su più righe, le saltiamo.
            if value.hasPrefix("'''") || value.hasPrefix("\"\"\"") {
                let q = String(value.prefix(3))
                if !value.dropFirst(3).contains(q) { skipUntil = q }
                continue
            }
            if value.hasPrefix("[") {
                if !value.contains("]") { skipUntil = "]" }
                continue
            }
            if value.hasPrefix("{") { continue }

            if let parsed = scalar(from: value) {
                var s = result[section] ?? [:]
                s[key] = parsed
                result[section] = s
            }
        }
        return result
    }

    private static func scalar(from raw: String) -> Any? {
        if raw.hasPrefix("\"") { return quoted(raw, quote: "\"") }
        if raw.hasPrefix("'") { return quoted(raw, quote: "'") }
        // valore "nudo": taglia un eventuale commento finale
        let bare = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        if bare == "true" { return true }
        if bare == "false" { return false }
        let cleaned = bare.replacingOccurrences(of: "_", with: "")
        if let i = Int(cleaned) { return i }
        if let d = Double(cleaned) { return d }
        return nil
    }

    /// Estrae il contenuto di una stringa tra virgolette, gestendo gli escape
    /// delle stringhe a doppio apice (quelle a singolo apice sono letterali).
    private static func quoted(_ raw: String, quote: Character) -> String? {
        var out = ""
        var escaped = false
        var closed = false
        for ch in raw.dropFirst() {
            if quote == "\"", escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default:  out.append(ch)
                }
                escaped = false
            } else if quote == "\"", ch == "\\" {
                escaped = true
            } else if ch == quote {
                closed = true
                break
            } else {
                out.append(ch)
            }
        }
        return closed ? out : nil
    }

    // MARK: - Scrittura

    /// Imposta `chiave` dentro `sezione`. Se la chiave esiste sostituisce solo
    /// quella riga (mantenendo un eventuale commento finale); se manca la
    /// inserisce subito sotto l'intestazione; se manca la sezione la aggiunge
    /// in fondo al file.
    static func setValue(_ text: String, section: String, key: String, value: Any) -> String {
        var rows = lines(of: text)
        let newText = format(value)
        let style = Style(of: text)

        var currentSection = ""
        var headerIndex: Int?
        var skipUntil: String?

        for (i, raw) in rows.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let closer = skipUntil {
                if line.contains(closer) { skipUntil = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), !line.hasPrefix("[["), let end = line.firstIndex(of: "]") {
                currentSection = String(line[line.index(after: line.startIndex)..<end])
                    .trimmingCharacters(in: .whitespaces)
                if currentSection == section { headerIndex = i }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if v.hasPrefix("'''") || v.hasPrefix("\"\"\"") {
                let q = String(v.prefix(3))
                if !v.dropFirst(3).contains(q) { skipUntil = q }
            } else if v.hasPrefix("["), !v.contains("]") {
                skipUntil = "]"
            }

            if currentSection == section, k == key {
                let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
                rows[i] = "\(indent)\(key) = \(newText)\(trailingComment(of: v))"
                return join(rows, style: style)
            }
        }

        if let h = headerIndex {
            rows.insert("\(key) = \(newText)", at: h + 1)
            return join(rows, style: style)
        }

        var out = rows
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        out.append("")
        out.append("[\(section)]")
        out.append("\(key) = \(newText)")
        return join(out, style: Style(eol: style.eol, trailingNewline: true))
    }

    /// Testo TOML di un valore scalare.
    static func format(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return String(i)
        case let d as Double:
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        default:
            let s = String(describing: value)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(s)\""
        }
    }

    // MARK: - Utility

    /// Commento finale della riga (` # ...`), se c'è, già preceduto da due spazi.
    private static func trailingComment(of value: String) -> String {
        var inQuote: Character?
        var prev: Character = " "
        for (offset, ch) in value.enumerated() {
            if let q = inQuote {
                if ch == q, prev != "\\" { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == "#", prev == " " || offset == 0 {
                let idx = value.index(value.startIndex, offsetBy: offset)
                return "  " + value[idx...]
            }
            prev = ch
        }
        return ""
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Fine riga e a-capo finale del file originale: si conservano così com'erano,
    /// altrimenti ogni modifica sporcherebbe il diff con righe che non c'entrano.
    private struct Style {
        var eol: String
        var trailingNewline: Bool
        init(eol: String, trailingNewline: Bool) { self.eol = eol; self.trailingNewline = trailingNewline }
        init(of text: String) {
            eol = text.contains("\r\n") ? "\r\n" : "\n"
            trailingNewline = text.hasSuffix("\n")
        }
    }

    private static func join(_ rows: [String], style: Style) -> String {
        var body = rows
        // `lines(of:)` produce una riga vuota finale quando il file termina con
        // a-capo: la togliamo e la rimettiamo secondo lo stile originale.
        if body.last == "" { body.removeLast() }
        var s = body.joined(separator: style.eol)
        if style.trailingNewline { s += style.eol }
        return s
    }
}
