import SwiftUI
import SwiftData
import UIKit
import AVFoundation

struct AutoCaptureFlow: View {

    let projects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var phase: Phase = .capturing
    @State private var lastData: Data?
    @State private var previewImage: UIImage?
    @State private var signature: SubjectSignature = .empty
    @State private var isCreatingProject = false
    @State private var classificationTask: Task<Void, Never>?
    @State private var isPreviewingMedia = false
    /// Basılı tutarak video kaydedildiyse geçici klip burada tutulur; bir projeye
    /// atanana kadar kalıcı depoya taşınmaz.
    @State private var pendingVideo: (url: URL, duration: Double)?
    /// Onay ekranındaki önizleme kartının en-boy oranı (genişlik / yükseklik);
    /// çekilen karenin ya da klibin kendi oranından gelir.
    @State private var mediaAspect: CGFloat = 0.75

    private let classifier: SubjectClassifying = SubjectClassifier()
    @State private var locationService = LocationService()

    /// Video klip için yalnızca Video kategorisi projeler eşleştirme/seçim adayıdır —
    /// fotoğraf odaklı bir projeye video karışmasın diye.
    private var candidateProjects: [Project] {
        pendingVideo != nil ? projects.filter { $0.category.isVideoMode } : projects
    }

    enum Phase: Equatable {
        case capturing
        case reviewing
        case classifying
        case confirming(UUID)
        case choosing(UUID?)
        case assigned(String)
    }

    var body: some View {
        ZStack {
            // Kamera yalnızca çekim aşamasında görünür. Daha önce onay ekranı canlı
            // arayüzün ÜSTÜNE yarı saydam biniyordu; zoom şeridi, deklanşör ve mod
            // anahtarı "Tekrar Çek"/"Vazgeç" düğmeleriyle çakışıyordu.
            CameraCaptureView(
                onAutoCaptured: handleCaptured,
                onVideoCaptured: handleVideoCaptured
            )
            .opacity(phase == .capturing ? 1 : 0)
            .allowsHitTesting(phase == .capturing)

            if phase != .capturing {
                Color.black.ignoresSafeArea()
            }

            switch phase {
            case .reviewing:
                reviewOverlay
            case .classifying:
                classifyingOverlay
            case .confirming(let id):
                if let project = projects.first(where: { $0.id == id }) {
                    confirmationOverlay(project)
                }
            case .assigned(let title):
                assignedOverlay(title)
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: choosingBinding) {
            AutoSortChoiceSheet(
                projects: candidateProjects,
                suggestedID: suggestedID,
                subjectLabel: subjectLabel,
                onSelect: assign(to:),
                onCreate: {
                    withAnimation { phase = .capturing }
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        isCreatingProject = true
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCreatingProject) {
            AddProjectSheet(
                repository: ProjectRepository(context: modelContext),
                suggestedCategory: pendingVideo != nil ? .video : signature.kind.suggestedCategory
            ) { project in
                assign(to: project)
            }
        }
        .fullScreenCover(isPresented: $isPreviewingMedia) {
            MediaPreviewCover(image: previewImage, videoURL: pendingVideo?.url)
        }
        .onDisappear {
            // Not: burada `discardPendingVideoFile()` çağrılmıyor — AVPlayerViewController'ın
            // kendi tam ekran genişlet/daralt geçişi bu view'ı geçici olarak "kaybolmuş"
            // gösteriyor ve bu onDisappear'ı gerçek bir kapanış olmadan tetikliyordu; sonuç,
            // tam ekrandan çıkınca video state'inin silinmesiydi. Gerçek kapanış noktaları
            // (closeFlow()) dosyayı zaten açıkça temizliyor; temp dizini sistem tarafından
            // da temizlenir.
            classificationTask?.cancel()
            classificationTask = nil
        }
    }

    /// Timelapse oluşturma sayfasının birebir düzeni: açık zemin, üstte "Kapat" ve
    /// başlık, ortada aynı önizleme kartı ve oynatıcı, altta tam genişlikte eylemler.
    private var reviewOverlay: some View {
        NavigationStack {
            ZStack {
                theme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        reviewPreviewArea
                        reviewActionArea
                    }
                    .padding(20)
                }
                .contentMargins(.bottom, 40, for: .scrollContent)
            }
            .navigationTitle(pendingVideo != nil ? "Video" : "Fotoğraf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { closeFlow() }
                }
            }
        }
    }

    /// Önizleme, kaydın kendi en-boy oranında gösterilir; dikey kayıtlarda yükseklik
    /// sabitlenip genişlik orandan türetilir, yatay kayıtlarda tersi.
    private var reviewPreviewArea: some View {
        Group {
            if mediaAspect <= 1 {
                reviewPreviewContent
                    .frame(width: 380 * mediaAspect, height: 380)
            } else {
                reviewPreviewContent
                    .aspectRatio(mediaAspect, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: mediaAspect)
    }

    private var reviewPreviewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(theme.surface)

            if let videoURL = pendingVideo?.url {
                ExportedVideoPlayer(url: videoURL)
                    .id(videoURL)
            } else if let image = previewImage {
                // `scaledToFit`: `scaledToFill` önerilen kutudan büyük bir boyut
                // bildirdiği için kırpma çerçevenin dışına taşıyordu.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .onTapGesture { isPreviewingMedia = true }
                    .accessibilityAddTraits(.isButton)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .clipped()
    }

    private var reviewActionArea: some View {
        VStack(spacing: 10) {
            Button {
                chooseProject()
            } label: {
                Label("Kullan", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.flapsePrimary)
            .accessibilityIdentifier("usePhotoButton")

            Button {
                resetPendingCapture()
                withAnimation { phase = .capturing }
            } label: {
                Label("Tekrar Çek", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(theme.accent)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("retakePhotoButton")

            Button {
                closeFlow()
            } label: {
                Text("Vazgeç")
                    .font(Theme.body(15))
                    .foregroundStyle(theme.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var classifyingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).controlSize(.large)
                Text(pendingVideo != nil ? "Video inceleniyor…" : "Kare tanınıyor…")
                    .font(Theme.headline(16)).foregroundStyle(.white)
            }
        }
        .transition(.opacity)
    }

    private func confirmationOverlay(_ project: Project) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 18) {
                if let image = previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                        .overlay(alignment: .topTrailing) { videoBadge }
                        .onTapGesture { isPreviewingMedia = true }
                        .accessibilityAddTraits(.isButton)
                }
                Image(systemName: Theme.icon(for: project.category))
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\"\(project.title)\" projesine eklensin mi?")
                    .font(Theme.headline(19)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button {
                        assign(to: project)
                    } label: {
                        Text("Evet, ekle")
                            .font(Theme.headline(16))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.black)
                    }
                    Button {
                        withAnimation { phase = .choosing(project.id) }
                    } label: {
                        Text("Başka proje seç")
                            .font(Theme.headline(15))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 22) {
                        Button {
                            resetPendingCapture()
                            withAnimation { phase = .capturing }
                        } label: {
                            Label("Tekrar Çek", systemImage: "arrow.counterclockwise")
                                .font(Theme.headline(14))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Button {
                            closeFlow()
                        } label: {
                            Text("Vazgeç")
                                .font(Theme.headline(14))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
        }
        .transition(.opacity)
    }

    private func assignedOverlay(_ title: String) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.white)
                Text("\(title) projesine eklendi")
                    .font(Theme.headline(18)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .transition(.opacity)
    }

    private var choosingBinding: Binding<Bool> {
        Binding(
            get: { if case .choosing = phase { true } else { false } },
            set: { newValue in
                if !newValue, case .choosing = phase { closeFlow() }
            }
        )
    }

    private var suggestedID: UUID? {
        if case .choosing(let id) = phase { return id }
        return nil
    }

    private var subjectLabel: String? {
        guard let label = signature.labels.first else { return nil }
        return Self.prettify(label)
    }

    private func handleCaptured(_ data: Data) {
        classificationTask?.cancel()
        pendingVideo = nil
        lastData = data
        previewImage = nil
        withAnimation { phase = .classifying }
        classificationTask = Task {
            let image = await ImageDownsampler.image(from: data, maxPixelSize: 1200)
            previewImage = image
            if let image, image.size.height > 0 {
                mediaAspect = image.size.width / image.size.height
            }
            await classifyAndRoute(posterData: data)
        }
    }

    /// Basılı tutarak video kaydedildiğinde çağrılır (Video kategorisi projeler için
    /// otomatik sıralama). Klip kalıcı depoya taşınmadan, poster kare üzerinden aynı
    /// yüz/obje tanıma ve proje eşleştirme akışı çalışır.
    private func handleVideoCaptured(_ url: URL, _ duration: Double, _ poster: Data?) {
        classificationTask?.cancel()
        pendingVideo = (url, duration)
        lastData = poster
        previewImage = nil
        withAnimation { phase = .classifying }
        classificationTask = Task {
            if let poster {
                previewImage = await ImageDownsampler.image(from: poster, maxPixelSize: 1200)
            }
            if let aspect = await Self.videoAspect(of: url) {
                mediaAspect = aspect
            }
            await classifyAndRoute(posterData: poster)
        }
    }

    /// Klibin ekranda göründüğü en-boy oranı: doğal boyut, kayıt sırasındaki cihaz
    /// yönelimini taşıyan `preferredTransform` ile döndürüldükten sonra hesaplanır.
    private static func videoAspect(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let displayed = size.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// Poster/foto verisi üzerinden imza hesaplar, uygun proje havuzuyla (video
    /// klipler yalnızca Video kategorisi projelerle) eşleştirip fazı belirler.
    private func classifyAndRoute(posterData: Data?) async {
        guard !Task.isCancelled else { return }
        await migrateSignaturesIfNeeded()
        guard !Task.isCancelled else { return }
        let computed: SubjectSignature
        if let posterData {
            computed = await classifier.signature(for: posterData)
        } else {
            computed = .empty
        }
        guard !Task.isCancelled else { return }
        signature = computed
        let pool = candidateProjects
        let sets = pool.compactMap(signatureSet(for:))
        switch ProjectMatcher.decide(for: computed, among: sets) {
        case .autoAssign(let id), .suggest(let id):
            if pool.contains(where: { $0.id == id }) {
                withAnimation { phase = .confirming(id) }
            } else {
                withAnimation { phase = .reviewing }
            }
        case .chooseManually:
            withAnimation { phase = .reviewing }
        }
        classificationTask = nil
    }

    private func chooseProject() {
        withAnimation { phase = .choosing(nil) }
    }

    private var videoBadge: some View {
        Group {
            if pendingVideo != nil {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(8)
            }
        }
    }

    /// Akışın gerçek kapanış noktaları buradan geçer: bekleyen video dosyası açıkça
    /// silinir (temp dizinin kendisi de temizlenir ama burada anında yapmak daha
    /// temiz), sonra kapatılır.
    private func closeFlow() {
        discardPendingVideoFile()
        dismiss()
    }

    private func resetPendingCapture() {
        discardPendingVideoFile()
        lastData = nil
        previewImage = nil
    }

    private func discardPendingVideoFile() {
        if let pendingVideo {
            try? FileManager.default.removeItem(at: pendingVideo.url)
        }
        pendingVideo = nil
    }

    private func assign(to project: Project) {
        if let pendingVideo {
            assignVideo(pendingVideo, poster: lastData, to: project)
            return
        }
        guard let data = lastData else { return }
        let repository = ProjectRepository(context: modelContext)
        let entry = Entry(
            imageData: data,
            subjectKindRaw: signature.kind == .unknown ? nil : signature.kind.rawValue,
            featurePrintData: signature.isEmpty ? nil : FeatureVector.data(from: signature.vector)
        )
        try? repository.addEntry(entry, to: project)
        lastData = nil
        previewImage = nil
        finishAssignment(to: project, entry: entry)
    }

    private func assignVideo(_ video: (url: URL, duration: Double), poster: Data?, to project: Project) {
        let repository = ProjectRepository(context: modelContext)
        let entryID = UUID()
        let destination = VideoEntryStorage.directory.appendingPathComponent(VideoEntryStorage.fileName(for: entryID))
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: video.url, to: destination)
        } catch {
            withAnimation { phase = .reviewing }
            return
        }
        let entry = Entry(
            id: entryID,
            imageData: poster,
            subjectKindRaw: signature.kind == .unknown ? nil : signature.kind.rawValue,
            featurePrintData: signature.isEmpty ? nil : FeatureVector.data(from: signature.vector),
            videoFileName: VideoEntryStorage.fileName(for: entryID),
            videoDuration: video.duration
        )
        try? repository.addEntry(entry, to: project)
        pendingVideo = nil
        lastData = nil
        previewImage = nil
        finishAssignment(to: project, entry: entry)
    }

    private func finishAssignment(to project: Project, entry: Entry) {
        let repository = ProjectRepository(context: modelContext)
        Task {
            if let resolved = await locationService.currentLocation() {
                entry.latitude = resolved.latitude
                entry.longitude = resolved.longitude
                entry.placeName = resolved.placeName
                try? repository.saveIfNeeded()
            }
        }
        withAnimation { phase = .assigned(project.title) }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        }
    }

    private static let signatureVersionKey = "autosort.signature.version"

    /// Yüz-odaklı imza (v2) öncesinde kaydedilmiş tüm-sahne imzalarını, projelerin son
    /// karelerinden bir kez yeniden hesaplar; eski projeler de yeni eşleştirmeden yararlanır.
    private func migrateSignaturesIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.signatureVersionKey) < 2 else { return }
        for project in projects {
            for entry in project.sortedEntries.suffix(8) {
                guard let data = entry.imageData else { continue }
                let sig = await classifier.signature(for: data)
                guard !sig.isEmpty else { continue }
                entry.featurePrintData = FeatureVector.data(from: sig.vector)
                if sig.kind != .unknown { entry.subjectKindRaw = sig.kind.rawValue }
            }
        }
        try? modelContext.save()
        defaults.set(2, forKey: Self.signatureVersionKey)
    }

    private func signatureSet(for project: Project) -> ProjectSignatureSet? {
        let entries = project.entries ?? []
        let vectors = entries.compactMap { entry -> [Float]? in
            guard let data = entry.featurePrintData else { return nil }
            let vector = FeatureVector.vector(from: data)
            return vector.isEmpty ? nil : vector
        }
        guard !vectors.isEmpty else { return nil }
        let kinds = entries.compactMap { $0.subjectKindRaw }.compactMap(SubjectKind.init(rawValue:))
        return ProjectSignatureSet(projectID: project.id, kind: Self.mostCommon(kinds) ?? .unknown, vectors: vectors)
    }

    private static func mostCommon(_ kinds: [SubjectKind]) -> SubjectKind? {
        guard !kinds.isEmpty else { return nil }
        var counts: [SubjectKind: Int] = [:]
        for kind in kinds { counts[kind, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func prettify(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct AutoSortChoiceSheet: View {

    let projects: [Project]
    let suggestedID: UUID?
    let subjectLabel: String?
    let onSelect: (Project) -> Void
    let onCreate: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var ordered: [Project] {
        guard let suggestedID, let index = projects.firstIndex(where: { $0.id == suggestedID }) else {
            return projects
        }
        var copy = projects
        copy.insert(copy.remove(at: index), at: 0)
        return copy
    }

    var body: some View {
        NavigationStack {
            List {
                if let subjectLabel {
                    Text("Bu karede: \(subjectLabel)")
                        .font(Theme.caption(13)).foregroundStyle(theme.inkMuted)
                        .listRowBackground(Color.clear)
                }
                ForEach(ordered) { project in
                    Button {
                        onSelect(project)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: Theme.icon(for: project.category))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.accent(for: project.category))
                                .frame(width: 44, height: 44)
                                .background(Theme.accent(for: project.category).opacity(0.15), in: Circle())
                            Text(project.title).font(Theme.headline(16)).foregroundStyle(theme.ink)
                            Spacer()
                            if project.id == suggestedID {
                                Text("Öneri")
                                    .font(Theme.caption(11)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(theme.accent, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                }
                Button {
                    onCreate()
                    dismiss()
                } label: {
                    Label("Yeni proje oluştur", systemImage: "plus.circle.fill")
                        .font(Theme.headline(16)).foregroundStyle(theme.accent)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Hangi projeye?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
            }
        }
    }
}

/// Küçük önizlemeye dokununca açılan tam ekran görünüm — video ise oynatır, fotoğrafsa
/// büyütülmüş halde gösterir. Kapatınca onay/inceleme ekranına geri dönülür.
private struct MediaPreviewCover: View {
    let image: UIImage?
    let videoURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let videoURL {
                AutoplayVideoPlayer(url: videoURL)
                    .ignoresSafeArea()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .liquidGlassBarCircle()
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
