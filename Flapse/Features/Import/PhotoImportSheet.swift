import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct PhotoImportSheet: View {

    enum Mode {
        case newProject
        case existing(Project)
    }

    enum PresentationStyle: Equatable {
        case sheet
        case embedded
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var viewModel: PhotoImportViewModel
    @State private var selection: [SelectedPhoto] = []
    @State private var isShowingPhotoPicker = false

    private let mode: Mode
    private let maxSelection: Int?
    private let presentationStyle: PresentationStyle
    private let onPhaseChange: (PhotoImportViewModel.Phase) -> Void
    private let onFinished: (Project) -> Void

    init(
        mode: Mode,
        repository: ProjectRepositoryProtocol,
        maxSelection: Int? = nil,
        presentationStyle: PresentationStyle = .sheet,
        onPhaseChange: @escaping (PhotoImportViewModel.Phase) -> Void = { _ in },
        onFinished: @escaping (Project) -> Void = { _ in }
    ) {
        self.mode = mode
        self.maxSelection = maxSelection
        self.presentationStyle = presentationStyle
        self.onPhaseChange = onPhaseChange
        self.onFinished = onFinished
        _viewModel = State(initialValue: PhotoImportViewModel(repository: repository))
    }

    /// İçe aktarma hedefi Video kategorisindeyse foto yerine video seçilir/eklenir.
    private var targetIsVideo: Bool {
        switch mode {
        case .existing(let project): return project.category.isVideoMode
        case .newProject: return viewModel.category.isVideoMode
        }
    }

    private func notifyFinishedIfNeeded() {
        let project: Project
        switch mode {
        case .existing(let existing):
            project = existing
        case .newProject:
            guard let completed = viewModel.completedProject else { return }
            project = completed
        }
        onFinished(project)
    }

    var body: some View {
        presentationContent
            .interactiveDismissDisabled(viewModel.phase == .importing)
            .onChange(of: viewModel.phase, initial: true) { _, phase in
                onPhaseChange(phase)
            }
            .onDisappear { notifyFinishedIfNeeded() }
            .fullScreenCover(isPresented: $isShowingPhotoPicker) {
                SystemPhotoPicker(maxSelectionCount: maxSelection, allowsVideo: targetIsVideo) { photos in
                    if !photos.isEmpty {
                        selection = photos
                    }
                    isShowingPhotoPicker = false
                } onCancel: {
                    isShowingPhotoPicker = false
                }
                .ignoresSafeArea()
            }
    }

    @ViewBuilder
    private var presentationContent: some View {
        if presentationStyle == .sheet {
            navigationContent
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.canvas)
        } else {
            navigationContent
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            content
                .background(theme.canvas)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case .configuring = viewModel.phase {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("İptal") { dismiss() }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .configuring: configuring
        case .importing: importing
        case .done(let count): done(count)
        case .failed(let message): failure(message)
        }
    }

    private var configuring: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    picker
                    if case .newProject = mode {
                        titleField
                        categoryRow
                        cadenceRow
                    } else if case .existing(let project) = mode {
                        targetRow(project)
                    }
                }
                .padding(20)
            }
            importButton
        }
    }

    private var picker: some View {
        Button {
            isShowingPhotoPicker = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: pickerIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(pickerTitle)
                        .font(Theme.headline(17)).foregroundStyle(theme.ink)
                    Text(pickerSubtitle)
                        .font(Theme.caption(13)).foregroundStyle(theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.inkMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private var pickerIcon: String {
        if !selection.isEmpty { return "checkmark.circle.fill" }
        return targetIsVideo ? "video.stack" : "photo.stack"
    }

    private var pickerTitle: String {
        if !selection.isEmpty {
            return targetIsVideo
                ? String(localized: "\(selection.count) video seçildi", bundle: .appLanguage)
                : String(localized: "\(selection.count) fotoğraf seçildi", bundle: .appLanguage)
        }
        return targetIsVideo
            ? String(localized: "Video Seç", bundle: .appLanguage)
            : String(localized: "Fotoğraf Seç", bundle: .appLanguage)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BAŞLIK").font(Theme.caption(12)).foregroundStyle(theme.inkMuted).tracking(1)
            TextField("ör. Tatil", text: $viewModel.title)
                .font(Theme.headline(20))
                .padding(16)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KATEGORİ").font(Theme.caption(12)).foregroundStyle(theme.inkMuted).tracking(1)
            HStack {
                Image(systemName: Theme.icon(for: viewModel.category)).foregroundStyle(theme.accent)
                Picker("Kategori", selection: $viewModel.category) {
                    ForEach(ProjectCategory.allCases.filter { !$0.isPro }) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .tint(theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var cadenceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ÇEKİM SIKLIĞI").font(Theme.caption(12)).foregroundStyle(theme.inkMuted).tracking(1)
            Picker("Sıklık", selection: $viewModel.cadence) {
                ForEach(CaptureCadence.allCases) { cadence in
                    Text(cadence.displayName).tag(cadence)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func targetRow(_ project: Project) -> some View {
        HStack(spacing: 14) {
            Image(systemName: Theme.icon(for: project.category))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent(for: project.category))
                .frame(width: 44, height: 44)
                .background(Theme.accent(for: project.category).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Şuraya eklenecek").font(Theme.caption(12)).foregroundStyle(theme.inkMuted)
                Text(project.title).font(Theme.headline(17)).foregroundStyle(theme.ink)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var importButton: some View {
        Button(action: startImport) {
            Text(importButtonTitle)
                .font(Theme.headline(17))
        }
        .buttonStyle(.flapsePrimary)
        .disabled(!canImport)
        .padding(20)
    }

    private var pickerSubtitle: String {
        if !selection.isEmpty { return String(localized: "Değiştirmek için dokun", bundle: .appLanguage) }
        if let maxSelection {
            return targetIsVideo
                ? String(localized: "En fazla \(maxSelection) video seçebilirsin (ücretsiz sınır)", bundle: .appLanguage)
                : String(localized: "En fazla \(maxSelection) fotoğraf seçebilirsin (ücretsiz sınır)", bundle: .appLanguage)
        }
        return targetIsVideo
            ? String(localized: "Kütüphanenden videolarını seçebilirsin", bundle: .appLanguage)
            : String(localized: "Kütüphanenden yüzlerce kare seçebilirsin", bundle: .appLanguage)
    }

    private var importButtonTitle: String {
        guard selection.isEmpty else { return String(localized: "İçeri aktar", bundle: .appLanguage) }
        return targetIsVideo
            ? String(localized: "Önce video seç", bundle: .appLanguage)
            : String(localized: "Önce fotoğraf seç", bundle: .appLanguage)
    }

    private var canImport: Bool {
        guard !selection.isEmpty else { return false }
        if case .newProject = mode { return viewModel.isValidNewProject }
        return true
    }

    private var importing: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: viewModel.progress)
                .progressViewStyle(.linear)
                .tint(theme.accent)
                .frame(maxWidth: 240)
            Text("İçe aktarılıyor… %\(Int(viewModel.progress * 100))")
                .font(Theme.headline(16)).foregroundStyle(theme.ink)
            Text("Kareler tarihe göre sıralanıyor")
                .font(Theme.caption(13)).foregroundStyle(theme.inkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func done(_ count: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.accent)
            Text("\(count) kare eklendi")
                .font(.system(size: 24, weight: .bold)).foregroundStyle(theme.ink)
            Text("Bu projeye çekmeye devam edebilirsin.")
                .font(Theme.caption(14)).foregroundStyle(theme.inkMuted)
                .multilineTextAlignment(.center)
            Spacer()
            Text("Geri dönmek için aşağı kaydır")
                .font(Theme.headline(15))
                .foregroundStyle(theme.inkMuted)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(theme.inkMuted)
            Text(message)
                .font(Theme.headline(16)).foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Kapat") { dismiss() }
                .buttonStyle(.flapsePrimary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func makeSource(index: Int, item: SelectedPhoto, isVideo: Bool) -> PhotoImportSource {
        var videoLoader: (() async -> URL?)?
        if isVideo {
            videoLoader = { await item.loadVideoFile() }
        }
        return PhotoImportSource(
            assetIdentifier: item.assetIdentifier,
            selectionIndex: index,
            load: { await item.loadData() },
            loadVideoFile: videoLoader
        )
    }

    private func startImport() {
        let isVideo = targetIsVideo
        var sources: [PhotoImportSource] = []
        sources.reserveCapacity(selection.count)
        for (index, item) in selection.enumerated() {
            sources.append(makeSource(index: index, item: item, isVideo: isVideo))
        }
        Task {
            switch mode {
            case .newProject:
                _ = await viewModel.importIntoNewProject(sources: sources)
            case .existing(let project):
                await viewModel.importInto(project: project, sources: sources)
            }
            if case .done = viewModel.phase {
                dismiss()
            }
        }
    }

    private var navigationTitle: String {
        if case .existing = mode {
            return targetIsVideo
                ? String(localized: "Video Ekle", bundle: .appLanguage)
                : String(localized: "Fotoğraf Ekle", bundle: .appLanguage)
        }
        return targetIsVideo
            ? String(localized: "Videolardan Oluştur", bundle: .appLanguage)
            : String(localized: "Fotoğraflardan Oluştur", bundle: .appLanguage)
    }
}

/// iOS 26's system sheet keeps a platform-defined horizontal margin even when
/// its corner radius is zero. The existing-project import flow intentionally
/// uses a transparent full-screen presentation with an edge-attached panel so
/// the panel is exactly as wide as the display while the project stays visible.
struct EdgeAttachedPhotoImportCover: View {
    let project: Project
    let repository: ProjectRepositoryProtocol
    let maxSelection: Int?
    let onFinished: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var canDismiss = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canDismiss { dismiss() }
                    }

                PhotoImportSheet(
                    mode: .existing(project),
                    repository: repository,
                    maxSelection: maxSelection,
                    presentationStyle: .embedded,
                    onPhaseChange: { phase in
                        canDismiss = phase != .importing
                    },
                    onFinished: onFinished
                )
                .frame(width: proxy.size.width)
                .frame(height: panelHeight(in: proxy.size.height))
                .background(theme.canvas)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 28,
                        topTrailingRadius: 28,
                        style: .continuous
                    )
                )
                .overlay(alignment: .top) { dragHandle }
                .offset(y: dragOffset)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("photoImportPanel")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .presentationBackground(.clear)
    }

    private var dragHandle: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())

            Capsule()
                .fill(theme.inkMuted.opacity(0.5))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
        }
        .frame(height: 28)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard canDismiss else { return }
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    guard canDismiss else {
                        dragOffset = 0
                        return
                    }
                    if value.translation.height > 90 || value.predictedEndTranslation.height > 180 {
                        dismiss()
                    } else {
                        withAnimation(.snappy(duration: 0.24)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityLabel(Text("Kapatmak için aşağı kaydır"))
        .accessibilityAddTraits(.isButton)
    }

    private func panelHeight(in availableHeight: CGFloat) -> CGFloat {
        min(availableHeight, max(420, availableHeight * 0.75))
    }
}

private struct SelectedPhoto: Identifiable, @unchecked Sendable {
    let id = UUID()
    let assetIdentifier: String?
    let provider: NSItemProvider

    func loadData() async -> Data? {
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
                }
            }
        }
    }

    /// Video klipleri `Data`'ya yüklenmez (bellek maliyeti) — geçici bir dosya
    /// URL'i olarak alınır, çağıran bunu kalıcı depoya kopyalar.
    func loadVideoFile() async -> URL? {
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .movie) == true
        } ?? UTType.movie.identifier

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("flapse-import-\(UUID().uuidString)")
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: temp)
                continuation.resume(returning: temp)
            }
        }
    }
}

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    let maxSelectionCount: Int?
    var allowsVideo: Bool = false
    let onComplete: ([SelectedPhoto]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = allowsVideo ? .videos : .images
        configuration.selectionLimit = maxSelectionCount ?? 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: SystemPhotoPicker

        init(parent: SystemPhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }
            parent.onComplete(results.map {
                SelectedPhoto(assetIdentifier: $0.assetIdentifier, provider: $0.itemProvider)
            })
        }
    }
}
