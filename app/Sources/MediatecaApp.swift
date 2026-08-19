import AppKit
import SwiftUI

@main
struct MediatecaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 660)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onAppear {
                    AppDelegate.model = model
                    AppDelegate.drainPending()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova serie…") { model.beginImport() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Apri video…") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Torna alla libreria") { model.stopPlayback() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.nowPlaying == nil)
            }
            CommandMenu("Conversione") {
                Button("Converti tutti i file non riproducibili") { model.convertPending() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Annulla conversioni in corso") { model.converter.cancelAll() }
                    .disabled(!model.converter.isBusy)
                Divider()
                Toggle("Sposta gli originali nel Cestino", isOn: Binding(
                    get: { model.converter.trashOriginals },
                    set: { model.converter.trashOriginals = $0 }
                ))
                Toggle("Imprimi i sottotitoli a immagine (PGS/VOBSUB)", isOn: Binding(
                    get: { model.converter.burnImageSubtitles },
                    set: { model.converter.burnImageSubtitles = $0 }
                ))
                Toggle("Attiva i sottotitoli automaticamente", isOn: Binding(
                    get: { model.autoSubtitles },
                    set: { model.autoSubtitles = $0 }
                ))
                Divider()
                Button("Indica dov'è ffmpeg…") { pickFFmpegFolder() }
            }
        }
    }

    /// Se ffmpeg è installato altrove (MacPorts, cartella personale), indicalo qui.
    private func pickFFmpegFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Seleziona la cartella che contiene ffmpeg e ffprobe (es. /opt/homebrew/bin)"
        if panel.runModal() == .OK, let u = panel.url {
            UserDefaults.standard.set(u.path, forKey: "ffmpegDir")
            model.alert = Converter.isAvailable
                ? "ffmpeg trovato in \(u.path)."
                : "In \(u.path) non ci sono ffmpeg e ffprobe."
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VideoTypes.contentTypes
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let u = panel.url {
            model.openExternal([u])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?
    @MainActor static var pending: [URL] = []

    /// Chiamato quando un video viene aperto dal Finder con “Apri con → Mediateca”.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let m = AppDelegate.model {
                m.openExternal(urls)
            } else {
                AppDelegate.pending += urls
            }
        }
    }

    @MainActor static func drainPending() {
        guard !pending.isEmpty, let m = model else { return }
        let urls = pending
        pending = []
        m.openExternal(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.model?.stopPlayback(save: true)
        }
    }
}
