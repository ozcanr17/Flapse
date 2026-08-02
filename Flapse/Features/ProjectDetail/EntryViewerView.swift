import SwiftUI
import SwiftData
import UIKit
import Photos
import AVFoundation

struct EntryViewerView: View {

    let project: Project
    let sourceEntries: [Entry]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(StoreService.self) private var store

    @State private var selectedEntryID: UUID
    @State private var isConfirmingDelete = false
    @State private var retakeTarget: Entry?
    @State private var editTarget: Entry?
    @State private var dateEditTarget: Entry?
    @State private var shareImage: UIImage?
    @State private var showPhotosDenied = false

    init(project: Project, initialEntry: Entry, entries: [Entry]) {
        self.project = project
        sourceEntries = entries
        _selectedEntryID = State(initialValue: initialEntry.id)
    }

    private var entries: [Entry] {
        var live: [Entry] = []
        live.reserveCapacity(sourceEntries.count)
        var isChronological = true
        var previousDate = Date.distantPast
        for entry in sourceEntries where !entry.isDeleted {
            if entry.capturedAt < previousDate {
                isChronological = false
            }
            previousDate = entry.capturedAt
            live.append(entry)
        }
        if !isChronological {
            live.sort { $0.capturedAt < $1.capturedAt }
        }
        guard !store.isPro else { return live }
        return Array(live.suffix(FeatureGate.freeEntryLimit))
    }

    private var selectedEntry: Entry? {
        entries.first { $0.id == selectedEntryID }
    }

    private var selectedIndex: Int? {
        entries.firstIndex { $0.id == selectedEntryID }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(entries) { entry in
                        EntryPage(entry: entry)
                            .containerRelativeFrame(.horizontal)
                            .id(entry.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: selectedEntryBinding)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomDock
            }
        }
        .environment(\.colorScheme, .dark)
        .confirmationDialog(
            "Bu çekim kalıcı olarak silinsin mi?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) { deleteSelected() }
            Button("Vazgeç", role: .cancel) {}
        }
        .fullScreenCover(item: $retakeTarget) { entry in
            CameraCaptureView(project: project, retakeEntry: entry)
        }
        .fullScreenCover(item: $editTarget) { entry in
            PhotoEditView(imageData: entry.imageData) { data in
                let repository = ProjectRepository(context: modelContext)
                try? repository.replaceImage(for: entry, with: data)
            }
        }
        .sheet(item: $dateEditTarget) { entry in
            EntryDateEditSheet(entry: entry) { date in
                try? ProjectRepository(context: modelContext).updateCapturedAt(for: entry, to: date)
                selectedEntryID = entry.id
            }
            .presentationDetents([.large])
        }
        .photosDeniedAlert(isPresented: $showPhotosDenied)
    }

    private var selectedEntryBinding: Binding<UUID?> {
        Binding(
            get: { selectedEntryID },
            set: { newValue in
                if let newValue { selectedEntryID = newValue }
            }
        )
    }

    private var topBar: some View {
        HStack {
            CameraControlButton(icon: "xmark", label: "Kapat") { dismiss() }
            Spacer()
            if let index = selectedIndex {
                Text(String(format: "No. %02d", index + 1))
                    .font(Theme.stamp(13))
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: 10) {
                if let shareImage {
                    ShareLink(item: Image(uiImage: shareImage), preview: SharePreview("Kare", image: Image(uiImage: shareImage))) {
                        controlIcon("square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("Kareyi paylaş"))
                }
                Button { saveToPhotos() } label: { controlIcon("square.and.arrow.down") }
                    .accessibilityLabel(Text("Fotoğraflara kaydet"))
                Button { isConfirmingDelete = true } label: { controlIcon("trash") }
                    .accessibilityLabel(Text("Kareyi sil"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .task(id: selectedEntry?.imageCacheKey) {
            guard let entry = selectedEntry else {
                shareImage = nil
                return
            }
            shareImage = await ImageDownsampler.cachedImage(
                key: "viewer-\(entry.imageCacheKey)",
                maxPixelSize: 2400,
                load: { entry.imageData }
            )
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .liquidGlassBarCircle()
    }

    private func saveToPhotos() {
        guard let image = shareImage else { return }
        Task {
            let outcome = await PhotoLibrarySaver.saveImage(image)
            if outcome == .denied {
                showPhotosDenied = true
            }
            UINotificationFeedbackGenerator().notificationOccurred(outcome == .saved ? .success : .error)
        }
    }

    @ViewBuilder
    private var bottomDock: some View {
        if let entry = selectedEntry {
            VStack(spacing: 12) {
                Button {
                    dateEditTarget = entry
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.capturedAt, format: .dateTime.weekday(.wide).day().month().year())
                                .font(Theme.headline(15))
                            Label(
                                entry.capturedAt.formatted(.dateTime.hour().minute().locale(AppLanguage.currentLocale)),
                                systemImage: "clock"
                            )
                            .font(Theme.caption(13))
                            .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Tarih ve saati düzenle"))
                if let place = entry.placeName, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(Theme.caption(13))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 10) {
                    Button {
                        editTarget = entry
                    } label: {
                        Label("Düzenle", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel(Text("Fotoğrafı düzenle"))

                    Button {
                        CameraService.shared.prewarm(
                            position: CameraCaptureViewModel.initialPosition(for: project.category),
                            videoCapable: CameraCaptureViewModel.sessionVideoCapable(for: project)
                        )
                        CameraLaunchIndicator.shared.show()
                        Task { @MainActor in retakeTarget = entry }
                    } label: {
                        Label("Yeniden Çek", systemImage: "camera.badge.clock")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(theme.accent, in: Capsule())
                    }
                }
                .font(Theme.headline(15))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.8)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        let index = selectedIndex ?? 0
        let repository = ProjectRepository(context: modelContext)
        withAnimation {
            try? repository.deleteEntry(entry)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            try? repository.saveIfNeeded()
        }

        let remaining = entries
        if remaining.isEmpty {
            dismiss()
        } else {
            selectedEntryID = remaining[min(index, remaining.count - 1)].id
        }
    }
}

private struct EntryDateEditSheet: View {
    let entry: Entry
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(entry: Entry, onSave: @escaping (Date) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _date = State(initialValue: entry.capturedAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Düzenle", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                DatePicker("Saat", selection: $date, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct EntryPage: View {
    let entry: Entry

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize?

    var body: some View {
        ZStack {
            if entry.isVideo {
                videoBody
            } else {
                photoBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Video girdileri oynatılabilir olmalı: daha önce burada yalnızca poster
    /// gösteriliyordu ve poster üretilememişse ekran tamamen siyah kalıyordu.
    @ViewBuilder
    private var videoBody: some View {
        if let url = entry.videoFileURL, FileManager.default.fileExists(atPath: url.path) {
            // Oynatıcı üst çubuk ile alt yuvanın arasında, ortalanmış olarak durur.
            // Tam ekran verildiğinde kendi kontrolleri bizim düğmelerimizle üst üste
            // biniyordu (ekranda üç kapatma ikonu görünüyordu).
            // Oynatıcı, üst çubuk ile alt yuvanın arasında ORTALANIR ve kendi
            // en-boy oranını korur. Tam ekran verildiğinde oynatıcının kendi
            // kontrolleri bizim düğmelerimizle üst üste biniyordu.
            SimpleVideoPlayer(url: url)
                .id(url)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 72)
                .padding(.bottom, 200)
        } else {
            ContentUnavailableView(
                "Video bulunamadı",
                systemImage: "video.slash",
                description: Text("Bu klibin dosyası cihazda bulunamadı.")
            )
            .foregroundStyle(.white)
        }
    }

    private var photoBody: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(zoomGesture)
                    .simultaneousGesture(zoom > 1 ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            if zoom > 1 {
                                zoom = 1
                                offset = .zero
                            } else {
                                zoom = 2.4
                            }
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: zoom == 1)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.imageCacheKey) {
            image = await ImageDownsampler.cachedImage(
                key: "viewer-\(entry.imageCacheKey)",
                maxPixelSize: 2400,
                load: { entry.imageData }
            )
        }
        .onChange(of: entry.id) {
            zoom = 1
            offset = .zero
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = zoom }
                zoom = min(max((pinchBase ?? 1) * value, 1), 5)
            }
            .onEnded { _ in
                pinchBase = nil
                if zoom <= 1.02 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        zoom = 1
                        offset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragBase == nil { dragBase = offset }
                let base = dragBase ?? .zero
                offset = CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height)
            }
            .onEnded { _ in dragBase = nil }
    }
}
