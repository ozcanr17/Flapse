import SwiftUI
import UniformTypeIdentifiers

/// Müzik seçim ekranı: hazır parçalar ve Dosyalar'dan daha önce seçilmiş "son
/// kullanılanlar" için önizleme (çal/duraklat) düğmesiyle bir liste sunar. Basit bir
/// `Menu` yerine bu görünüme geçildi çünkü kullanıcı seçmeden önce dinleyebilmeli.
struct MusicPickerSheet: View {
    var selectedTitle: String?
    let onSelect: (URL?, String?, [Double]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var preview = SoundtrackPreviewPlayer()
    @State private var recents: [RecentSoundtracks.Entry] = []
    @State private var isPickingFile = false
    @State private var query = ""

    private var filteredBundled: [SoundtrackOption] {
        let all = SoundtrackOption.bundled
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var filteredRecents: [RecentSoundtracks.Entry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return recents }
        return recents.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Button {
                            choose(url: nil, title: nil, beats: nil)
                        } label: {
                            HStack {
                                Text("Kapalı")
                                Spacer()
                                if selectedTitle == nil {
                                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(theme.ink)
                    }
                }

                if !filteredBundled.isEmpty {
                    Section {
                        ForEach(filteredBundled) { option in
                            trackRow(id: option.id, title: option.title, url: option.url) {
                                choose(url: option.url, title: option.title, beats: option.beatGrid)
                            }
                        }
                    } header: {
                        Text("Hazır parçalar")
                    }
                }

                if !filteredRecents.isEmpty {
                    Section {
                        ForEach(filteredRecents) { entry in
                            trackRow(id: entry.id, title: entry.title, url: entry.url) {
                                choose(url: entry.url, title: entry.title, beats: nil)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    preview.stop()
                                    RecentSoundtracks.remove(entry)
                                    recents = RecentSoundtracks.all()
                                } label: {
                                    Label("Kaldır", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Son kullanılanlar")
                    }
                }

                if filteredBundled.isEmpty && filteredRecents.isEmpty {
                    Text("Eşleşen parça yok")
                        .foregroundStyle(theme.inkMuted)
                        .listRowSeparator(.hidden)
                }

                Section {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Dosyadan seç…", systemImage: "folder")
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: Text("Parça ara"))
            .navigationTitle("Müzik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .onAppear { recents = RecentSoundtracks.all() }
        .onDisappear { preview.stop() }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("soundtrack-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
            guard (try? FileManager.default.copyItem(at: url, to: local)) != nil else { return }
            let title = url.deletingPathExtension().lastPathComponent
            Task {
                let prepared = await SoundtrackTranscoder.aacFile(from: local)
                let saved = RecentSoundtracks.add(sourceURL: prepared, title: title)
                choose(url: saved?.url ?? prepared, title: title, beats: nil)
            }
        }
    }

    private func choose(url: URL?, title: String?, beats: [Double]?) {
        preview.stop()
        onSelect(url, title, beats)
        dismiss()
    }

    private func trackRow(id: String, title: String, url: URL, onChoose: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button {
                preview.toggle(id: id, url: url)
            } label: {
                Image(systemName: preview.playingID == id ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(preview.playingID == id ? "Duraklat" : "Dinle"))
            .accessibilityHint(Text(title))

            Text(title)
                .foregroundStyle(theme.ink)

            Spacer()

            if selectedTitle == title {
                Image(systemName: "checkmark").foregroundStyle(theme.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
    }
}
