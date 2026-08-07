import SwiftUI

/// Barra in fondo alla libreria: compare solo quando ci sono conversioni in corso.
struct ConversionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var converter: Converter

    private var current: Converter.Job? {
        converter.jobs.first { if case .running = $0.state { return true }; return false }
            ?? converter.jobs.first { $0.state == .waiting }
    }

    private var queued: Int { converter.jobs.filter { $0.state == .waiting }.count }
    private var failed: [Converter.Job] {
        converter.jobs.filter { if case .failed = $0.state { return true }; return false }
    }

    var body: some View {
        if !converter.activeJobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 3) {
                        if let job = current {
                            HStack(spacing: 6) {
                                Text("Conversione: \(job.title)")
                                    .font(.callout).bold().lineLimit(1)
                                if job.burnedIn {
                                    Text("sottotitoli impressi · ricodifica")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.orange.opacity(0.22), in: Capsule())
                                } else if job.remuxOnly {
                                    Text("remux · senza perdita di qualità")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.18), in: Capsule())
                                }
                            }
                            if case .running(let p) = job.state {
                                ProgressView(value: p)
                                    .frame(width: 320)
                                Text("\(Int(p * 100))%\(queued > 0 ? " · \(queued) in coda" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("In attesa…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !failed.isEmpty {
                            Text("\(failed.count) non riuscite")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    Toggle("Sposta gli originali nel Cestino", isOn: $converter.trashOriginals)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("A conversione riuscita l'originale va nel Cestino, non viene eliminato definitivamente.")

                    Button("Annulla") { converter.cancelAll() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

/// Badge di stato mostrato nella riga dell'episodio.
struct ConversionBadge: View {
    let state: Converter.State

    var body: some View {
        switch state {
        case .waiting:
            label("In coda per la conversione", "clock", .secondary)
        case .running(let p):
            label("Conversione \(Int(p * 100))%", "arrow.triangle.2.circlepath", .accentColor)
        case .done:
            EmptyView()
        case .failed:
            label("Conversione non riuscita", "exclamationmark.triangle.fill", .orange)
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }
}
