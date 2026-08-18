import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pannello di importazione: scegli i file, dai un titolo alla serie e una stagione.
struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: ImportDraft
    @State private var showPicker = false
    @State private var isMovie = false

    private var isAddingToExisting: Bool { draft.targetSeriesID != nil }

    private var needConversion: Int {
        draft.items.filter {
            !Episode.playableExtensions.contains($0.url.pathExtension.lowercased())
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if draft.items.isEmpty {
                emptyPicker
            } else {
                fileList
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        // Un NSOpenPanel modale aperto da dentro uno sheet può non comparire
        // affatto: `fileImporter` lo presenta correttamente come sotto-sheet.
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: VideoTypes.contentTypes + [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            let videos = VideoTypes.collect(urls)
            if videos.isEmpty {
                model.alert = "In quella selezione non ci sono file video riconoscibili."
            } else {
                draft.add(videos)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(headerTitle).font(.title2).bold()
                Spacer()
                if !isAddingToExisting {
                    Picker("", selection: $isMovie) {
                        Text("Serie tv").tag(false)
                        Text("Film").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isMovie ? "Titolo del film" : "Titolo")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(isMovie ? "Es. Ritorno al futuro" : "Es. Steins;Gate",
                              text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isAddingToExisting)
                }
                if !isMovie {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stagione").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $draft.season, in: 1...99) {
                            Text("\(draft.season)").monospacedDigit().frame(width: 28, alignment: .leading)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Etichetta stagione (opzionale)").font(.caption).foregroundStyle(.secondary)
                        TextField("Es. Prima stagione", text: $draft.seasonName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                }
            }
        }
        .padding(20)
    }

    private var headerTitle: String {
        if isAddingToExisting { return "Aggiungi episodi" }
        return isMovie ? "Nuovo film" : "Nuova serie"
    }

    // MARK: Selezione file

    private var emptyPicker: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("Scegli gli episodi da caricare")
                .font(.headline)
            Text("Numero di episodio e stagione vengono riconosciuti automaticamente\ndai nomi dei file (es. “S01E04”, “Ep 04”).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Scegli file…") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            if needConversion > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays").foregroundStyle(.tint)
                    Text("\(needConversion) file da convertire in MP4: parte da solo dopo l'aggiunta.")
                        .font(.callout)
                    Spacer()
                    Toggle("Originali nel Cestino", isOn: Binding(
                        get: { model.converter.trashOriginals },
                        set: { model.converter.trashOriginals = $0 }
                    ))
                    .toggleStyle(.checkbox).font(.caption)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(.tint.opacity(0.08))
            }

            HStack {
                Text("\(draft.items.count) episodi — trascina per riordinare")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rinumera 1…\(draft.items.count)") {
                    for i in draft.items.indices { draft.items[i].number = i + 1 }
                }
                .controlSize(.small)
                Button("Aggiungi altri…") { showPicker = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            List {
                ForEach($draft.items) { $item in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        TextField("N.", value: $item.number, format: .number)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading, spacing: 1) {
                            TextField("Titolo episodio", text: $item.title)
                                .textFieldStyle(.plain)
                            Text(item.url.lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            draft.items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    draft.items.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Annulla") { model.importer = nil }
                .keyboardShortcut(.cancelAction)

            if isMovie && draft.items.count > 1 {
                Text("Un film ha un solo file: verrà usato il primo.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer()
            Button(confirmLabel) {
                var toCommit = draft
                if isMovie {
                    // Un film è modellato come Series con 1 stagione da 1 episodio.
                    toCommit.isMovie = true
                    toCommit.season = 1
                    toCommit.seasonName = ""
                    if toCommit.items.count > 1 {
                        toCommit.items = Array(toCommit.items.prefix(1))
                    }
                    toCommit.items = toCommit.items.map { item in
                        var m = item; m.number = 1; return m
                    }
                }
                model.commitImport(toCommit)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(draft.items.isEmpty || (!isAddingToExisting && draft.title.trimmingCharacters(in: .whitespaces).isEmpty))
        }
        .padding(16)
    }

    private var confirmLabel: String {
        if isAddingToExisting { return "Aggiungi \(draft.items.count) episodi" }
        return isMovie ? "Aggiungi film" : "Crea serie"
    }

    // MARK: Azioni

}
