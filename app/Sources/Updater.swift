import AppKit
import Foundation

/// Gestisce l'aggiornamento dell'app dal proprio repository git.
///
/// Flusso:
///   1. Legge il path della checkout da `Contents/Resources/repo_path`
///      (viene scritto lì da build.sh e install.sh la prima volta).
///   2. `git fetch` per capire se ci sono commit nuovi.
///   3. Al comando dell'utente: `git pull`, poi `app/build.sh`, poi
///      lancia uno script trampolino che aspetta la chiusura dell'app
///      e la riapre col nuovo bundle.
@MainActor
final class Updater: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(sha: String, when: String)
        case updateAvailable(commits: Int, sha: String, message: String)
        case updating(progress: String)
        case ready              // scaricato, pronto al riavvio
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: String = ""

    /// Cartella della checkout git di Mediateca. `nil` se il file
    /// `repo_path` non c'è o punta a un percorso non più valido.
    var repoDir: URL? {
        // Il file può stare o dentro il bundle installato (caso normale)
        // o accanto ai sorgenti durante lo sviluppo.
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("repo_path"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications/Mediateca.app/Contents/Resources/repo_path"),
        ].compactMap { $0 }

        for file in candidates {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
        }
        return nil
    }

    var isConfigured: Bool { repoDir != nil }

    // MARK: - Azioni pubbliche

    func check() {
        guard let repo = repoDir else {
            phase = .failed("Percorso della repository non trovato. "
                          + "Rilancia l'installazione con:  bash install.sh")
            return
        }
        phase = .checking
        Task {
            let out = await runGit(["fetch", "--quiet"], in: repo)
            guard out.exit == 0 else {
                phase = .failed(out.err.isEmpty
                                ? "git fetch non riuscito." : out.err)
                return
            }

            // HEAD locale
            let localSha = (await runGit(["rev-parse", "HEAD"], in: repo)).out
            // Numero di commit tra HEAD locale e remoto
            let branch = (await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)).out
            let behind = (await runGit(
                ["rev-list", "--count", "HEAD..origin/\(branch)"], in: repo)).out
            let count = Int(behind) ?? 0

            if count == 0 {
                let when = (await runGit(
                    ["log", "-1", "--pretty=format:%cr", "HEAD"], in: repo)).out
                phase = .upToDate(sha: String(localSha.prefix(7)),
                                  when: when.isEmpty ? "adesso" : when)
            } else {
                let head = (await runGit(
                    ["rev-parse", "origin/\(branch)"], in: repo)).out
                let msg = (await runGit(
                    ["log", "-1", "--pretty=format:%s", "origin/\(branch)"], in: repo)).out
                phase = .updateAvailable(commits: count,
                                         sha: String(head.prefix(7)),
                                         message: msg)
            }
        }
    }

    func installUpdate() {
        guard let repo = repoDir else { return }
        log = ""
        phase = .updating(progress: "Scarico gli aggiornamenti…")
        Task {
            let pull = await runGit(["pull", "--ff-only"], in: repo, capture: true)
            appendLog(pull.out); appendLog(pull.err)
            guard pull.exit == 0 else {
                phase = .failed("git pull non riuscito.\n\(pull.err)")
                return
            }

            phase = .updating(progress: "Compilo la nuova versione…")
            let build = await runShell(
                ["/bin/bash", repo.appendingPathComponent("app/build.sh").path],
                cwd: repo.appendingPathComponent("app"),
                capture: true
            )
            appendLog(build.out); appendLog(build.err)
            guard build.exit == 0 else {
                phase = .failed("Compilazione non riuscita. Apri i log per capire perché.")
                return
            }
            phase = .ready
        }
    }

    /// Termina questa istanza dell'app e la riapre con il nuovo bundle.
    /// Usa un piccolo trampolino bash che aspetta la nostra chiusura,
    /// così macOS non prova a fondere due processi.
    func restart() {
        guard let appURL = installedAppURL() else {
            NSApp.terminate(nil); return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.4
        open -n "\(appURL.path)"
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediateca-relaunch-\(pid).sh")
        try? script.write(to: tmp, atomically: true, encoding: .utf8)
        _ = chmod(tmp.path, 0o755)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [tmp.path]
        try? p.run()

        NSApp.terminate(nil)
    }

    // MARK: - Utility

    private func installedAppURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications/Mediateca.app"),
            URL(fileURLWithPath: "/Applications/Mediateca.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? Bundle.main.bundleURL
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        log += text
        if !log.hasSuffix("\n") { log += "\n" }
        if log.count > 40_000 { log = String(log.suffix(20_000)) }
    }

    private struct ProcOutput { let out: String; let err: String; let exit: Int32 }

    private func runGit(_ args: [String], in repo: URL, capture: Bool = false) async -> ProcOutput {
        await runShell(["/usr/bin/env", "git", "-C", repo.path] + args, cwd: repo, capture: capture)
    }

    /// Accumulatore reference-type per stdout/stderr: le closure di
    /// readabilityHandler e terminationHandler girano su thread diversi,
    /// quindi mutare due `var Data` catturate porta warning di
    /// concorrenza in Swift 6. Un lock rende esplicita la sincronizzazione.
    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        func drain() -> Data { lock.lock(); let d = data; data.removeAll(); lock.unlock(); return d }
    }

    /// Lancia un comando come sottoprocesso e cattura stdout/stderr.
    private func runShell(_ argv: [String], cwd: URL, capture: Bool) async -> ProcOutput {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcOutput, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            p.currentDirectoryURL = cwd
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            let outBuf = Buffer(), errBuf = Buffer()
            if capture {
                out.fileHandleForReading.readabilityHandler = { [weak self] h in
                    let d = h.availableData
                    if d.isEmpty { return }
                    outBuf.append(d)
                    if let s = String(data: d, encoding: .utf8) {
                        Task { @MainActor [weak self] in self?.appendLog(s) }
                    }
                }
                err.fileHandleForReading.readabilityHandler = { [weak self] h in
                    let d = h.availableData
                    if d.isEmpty { return }
                    errBuf.append(d)
                    if let s = String(data: d, encoding: .utf8) {
                        Task { @MainActor [weak self] in self?.appendLog(s) }
                    }
                }
            }

            p.terminationHandler = { proc in
                if capture {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                } else {
                    outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                }
                let outStr = String(data: outBuf.drain(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errStr = String(data: errBuf.drain(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: ProcOutput(out: outStr, err: errStr,
                                                  exit: proc.terminationStatus))
            }
            do { try p.run() } catch {
                cont.resume(returning: ProcOutput(out: "", err: error.localizedDescription,
                                                  exit: -1))
            }
        }
    }
}
