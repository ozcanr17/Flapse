import SwiftUI
import SwiftData
import UIKit
import CoreLocation
import CloudKit
import MapKit
import UniformTypeIdentifiers

struct ProjectDetailView: View {

    let project: Project

    @Query private var fetchedEntries: [Entry]

    @Environment(\.modelContext) private var modelContext
    @Environment(StoreService.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.customTabBarHidden) private var customTabBarHidden

    @State private var shareCardURL: URL?
    @State private var heroImage: UIImage?
    @State private var activeSheet: DetailSheet?
    @State private var activeCover: DetailCover?
    @State private var isShowingPhotoImport = false
    @State private var monthFilter: MonthKey?
    @State private var preparedShare: CKShare?
    @State private var isPreparingShare = false
    @State private var isChoosingShareCard = false
    @State private var isSelectingEntries = false
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var showsAllTimelineEntries = false
    @State private var isRevealingTimelineEntries = false
    @State private var archiveTempURL: URL?
    @State private var archiveExportItem: ArchiveExportItem?
    @State private var isExportingArchive = false
    @State private var archiveExportError: String?
    @State private var pendingShareAction: ProjectShareAction?
    @State private var isRenderingShareCard = false
    @State private var shareCardCreationFailed = false

    private static let initialTimelineEntryCount = 10
    fileprivate static let timelinePreviewPixelSize: CGFloat = 480

    private struct MonthKey: Hashable {
        let year: Int
        let month: Int
    }

    init(project: Project) {
        self.project = project
        let projectID = project.id
        _fetchedEntries = Query(
            filter: #Predicate<Entry> { entry in
                entry.project?.id == projectID && entry.deletedAt == nil
            },
            sort: [SortDescriptor(\.capturedAt)]
        )
    }

    private enum DetailSheet: Identifiable {
        case export, paywall, invite, cloudShare, editProject, shareCard, batchDate, batchLocation
        var id: Int { hashValue }
    }

    private enum DetailCover: Identifiable {
        case capture
        case viewer(Entry)
        var id: String {
            switch self {
            case .capture: "capture"
            case .viewer(let entry): entry.id.uuidString
            }
        }
    }

    private struct ArchiveExportItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var canAddEntry: Bool {
        FeatureGate.canAddEntry(isPro: store.isPro, currentEntryCount: liveEntries.count)
    }

    private var accent: Color { Theme.accent(for: project.category) }

    /// Her proje açılışı kendi izini kullanır; ortak bir ad, üst üste binen
    /// gezinmelerde işaretleri karıştırıp gerçekte olmayan saniyeler üretiyordu.
    private var traceName: String { "project-\(project.id.uuidString.prefix(8))" }

    private var liveEntries: [Entry] {
        fetchedEntries
    }

    private var isCaptureDue: Bool {
        project.cadence.isCaptureDue(lastCapture: liveEntries.last?.capturedAt)
    }

    private var selectedEntries: [Entry] {
        liveEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    var body: some View {

        let _ = PerfTrace.mark(traceName, "body evaluated")
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(project.title)
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .padding(.top, 2)

                heroCard

                if !liveEntries.isEmpty {
                    statsRow
                }

                if !project.collaboratorNames.isEmpty {
                    collaboratorsRow
                }

                if !store.isPro {
                    freeQuotaBadge
                }

                captureCTA

                if liveEntries.count >= 2 {
                    exportButton
                }

                if liveEntries.isEmpty {
                    emptyState
                } else {
                    timeline
                }
            }
            .padding(16)
        }
        .background(theme.canvas.ignoresSafeArea())
        .onAppear { PerfTrace.end(traceName, "detay göründü") }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingEntries {
                selectionActionBar
            }
        }
        .onAppear {
            customTabBarHidden.wrappedValue = true
        }
        .onDisappear {
            customTabBarHidden.wrappedValue = false
        }
        .task(id: project.cloudShareRecordName) {
            guard project.isCollaborative, SharedProjectService.isEnabledForCurrentProcess else { return }
            while !Task.isCancelled {
                await SharedProjectService.shared.synchronize(project, context: modelContext)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .toolbar {
            if !liveEntries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isChoosingShareCard = true
                    } label: {
                        toolbarIcon("square.and.arrow.up", yOffset: -1.5)
                    }
                    .accessibilityLabel(Text("Projeyi paylaş"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .editProject
                } label: {
                    toolbarIcon("pencil")
                }
                .accessibilityIdentifier("editButton")
                .accessibilityLabel(Text("Projeyi düzenle"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importTapped()
                } label: {
                    toolbarIcon("photo.badge.plus")
                }
                .accessibilityIdentifier("importButton")
                .accessibilityLabel(Text("Fotoğraf ekle"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inviteTapped()
                } label: {
                    if isPreparingShare {
                        ProgressView()
                            .tint(accent)
                            .frame(width: 30, height: 30)
                    } else {
                        toolbarIcon(project.isCollaborative ? "person.2.fill" : "person.badge.plus")
                    }
                }
                .disabled(isPreparingShare)
                .accessibilityIdentifier("inviteButton")
                .accessibilityLabel(Text("Birlikte çekim daveti"))
            }
        }
        .sheet(isPresented: $isChoosingShareCard, onDismiss: performPendingShareAction) {
            ProjectShareOptionsSheet(canCreateComparison: liveEntries.count >= 2) { action in
                pendingShareAction = action
            }
        }
        .sheet(item: $activeSheet, onDismiss: cleanupShareCard) { sheet in
            switch sheet {
            case .export:
                TimelapseExportSheet(project: project)
            case .paywall:
                PaywallView(store: store)
            case .invite:
                ActivityView(activityItems: [inviteText])
            case .editProject:
                EditProjectSheet(project: project)
            case .shareCard:
                if let shareCardURL {
                    ActivityView(activityItems: [shareCardURL])
                }
            case .cloudShare:
                if let preparedShare, let url = preparedShare.url {
                    ActivityView(activityItems: [inviteMessage, url])
                } else {
                    ActivityView(activityItems: [inviteText])
                }
            case .batchDate:
                BatchDateEditSheet(
                    count: selectedEntries.count,
                    initialDate: selectedEntries.first?.capturedAt ?? .now
                ) { date, preservingTime in
                    try? ProjectRepository(context: modelContext).updateCapturedAt(
                        for: selectedEntries,
                        to: date,
                        preservingTime: preservingTime
                    )
                    finishSelection()
                }
                .presentationDetents([.large])
            case .batchLocation:
                BatchLocationEditSheet(count: selectedEntries.count) { location in
                    try? ProjectRepository(context: modelContext).updateLocation(
                        for: selectedEntries,
                        latitude: location?.latitude,
                        longitude: location?.longitude,
                        placeName: location?.placeName
                    )
                    finishSelection()
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $archiveExportItem, onDismiss: cleanupArchiveExport) { item in
            ProjectArchiveExportPicker(sourceURL: item.url)
                .ignoresSafeArea()
        }
        .overlay {
            if isRenderingShareCard {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                        .padding(22)
                        .liquidGlassBarCapsule()
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if isExportingArchive {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Arşiv hazırlanıyor…")
                            .font(Theme.body(14))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .liquidGlassBarCapsule()
                }
                .transition(.opacity)
            }
        }
        .alert("Paylaş", isPresented: $shareCardCreationFailed) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "Beklenmeyen bir hata oluştu: %@", bundle: .appLanguage),
                    String(localized: "Paylaş", bundle: .appLanguage)
                )
            )
        }
        .alert("Arşiv oluşturulamadı", isPresented: Binding(
            get: { archiveExportError != nil },
            set: { if !$0 { archiveExportError = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(archiveExportError ?? "")
        }
        .background {
            Color.clear
                .fullScreenCover(item: $activeCover) { cover in
                    let _ = CameraLaunchTrace.mark("cover content building")
                    switch cover {
                    case .capture:
                        CameraCaptureView(project: project)
                    case .viewer(let entry):
                        EntryViewerView(project: project, initialEntry: entry, entries: liveEntries)
                    }
                }
        }
        .fullScreenCover(isPresented: $isShowingPhotoImport) {
            EdgeAttachedPhotoImportCover(
                project: project,
                repository: ProjectRepository(context: modelContext),
                maxSelection: store.isPro ? nil : max(0, FeatureGate.freeEntryLimit - liveEntries.count),
                onFinished: { _ in isShowingPhotoImport = false }
            )
        }
    }

    private func cleanupArchiveExport() {
        if let archiveTempURL {
            try? FileManager.default.removeItem(at: archiveTempURL.deletingLastPathComponent())
        }
        archiveTempURL = nil
        archiveExportItem = nil
    }

    private func cleanupShareCard() {
        if let shareCardURL {
            try? FileManager.default.removeItem(at: shareCardURL)
        }
        shareCardURL = nil
    }

    /// Bugünün karesini çekmek için ana çağrı — kamerayı prim konumda, büyük bir
    /// düğmeyle açar. Uygulamanın asıl amacı bu olduğundan öne çıkarıyoruz.
    private var captureCTA: some View {
        let due = isCaptureDue
        return Button {
            if canAddEntry {
                CameraLaunchTrace.begin("project detail CTA")
                CameraService.shared.prewarm(
                    position: CameraCaptureViewModel.initialPosition(for: project.category),
                    videoCapable: CameraCaptureViewModel.sessionVideoCapable(for: project),
                    micEnabled: project.category.isVideoMode
                )
                CameraLaunchTrace.mark("prewarm dispatched")
                CameraLaunchIndicator.shared.show()
                Task { @MainActor in
                    CameraLaunchTrace.mark("overlay frame yielded")
                    activeCover = .capture
                    CameraLaunchTrace.mark("activeCover set")
                }
            } else {
                activeSheet = .paywall
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.22)).frame(width: 46, height: 46)
                    Image(systemName: project.category.isVideoMode ? "video.fill" : "camera.fill")
                        .font(.system(size: 20, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(captureCTATitle(due: due))
                        .font(Theme.headline(18))
                    Text(canAddEntry ? "Sıradaki: No. \(liveEntries.count + 1)" : "Ücretsiz sınır doldu — Pro")
                        .font(Theme.caption(12)).opacity(0.9)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
            .overlay(alignment: .topTrailing) {
                if due {
                    Circle().fill(.white).frame(width: 10, height: 10).padding(12)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("captureButton")
    }

    private func captureCTATitle(due: Bool) -> String {
        if project.category.isVideoMode {
            return due
                ? String(localized: "Bugünün videosunu çek", bundle: .appLanguage)
                : String(localized: "Yeni video ekle", bundle: .appLanguage)
        }
        return due
            ? String(localized: "Bugünün karesini çek", bundle: .appLanguage)
            : String(localized: "Yeni kare ekle", bundle: .appLanguage)
    }

    private var collaboratorsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
            Text(project.collaboratorNames.joined(separator: ", "))
                .font(Theme.caption(13))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toolbarIcon(_ name: String, yOffset: CGFloat = 0) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(accent)
            .frame(width: 21, height: 21)
            .offset(y: yOffset)
            .frame(width: 30, height: 30, alignment: .center)
    }

    /// Davet bağlantısının yanına eklenen, uygulama diline göre yazılmış kısa davet metni.
    private var inviteMessage: String {
        String(localized: "Flapse'te \"\(project.title)\" projesine katıl — birlikte çekelim! Bağlantıya dokunman yeterli. 📸", bundle: .appLanguage)
    }

    private var inviteText: String {
        String(localized: "Flapse'te \"\(project.title)\" projesinde birlikte çekim yapalım! Uygulamayı indirip aynı hikayeyi birlikte biriktirelim. 📸", bundle: .appLanguage)
    }

    /// Birlikte Çekim: arkadaşları davet edip aynı projeye birlikte katkı yapmak için
    /// sistem paylaşım sayfasını açar (Pro). Ücretsiz kullanıcı paywall görür.
    private func importTapped() {
        if store.isPro || liveEntries.count < FeatureGate.freeEntryLimit {
            isShowingPhotoImport = true
        } else {
            activeSheet = .paywall
        }
    }

    private func inviteTapped() {
        guard store.isPro else {
            activeSheet = .paywall
            return
        }
        Task { await prepareShare() }
    }

    /// iCloud varsa gerçek CloudKit paylaşımı oluşturur ve sistem paylaşım ekranını açar;
    /// iCloud yoksa metin davetine düşer.
    private func prepareShare() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        guard await SharedProjectService.accountAvailableIfSupported() else {
            activeSheet = .invite
            return
        }

        do {
            let share = try await SharedProjectService.shared.createShare(project: project)
            try? modelContext.save()
            preparedShare = share
            activeSheet = .cloudShare
        } catch {
            activeSheet = .invite
        }
    }

    private func applyShare(_ share: CKShare) {
        let names = SharedProjectService.participantNames(of: share)
        if !names.isEmpty {
            project.collaboratorNamesRaw = names.joined(separator: "\n")
        }
        project.cloudShareRecordName = share.recordID.recordName
        try? modelContext.save()
    }

    private var freeQuotaBadge: some View {
        let count = liveEntries.count
        let atLimit = count >= FeatureGate.freeEntryLimit
        return HStack(spacing: 8) {
            Image(systemName: atLimit ? "lock.fill" : "camera.badge.clock")
                .font(.system(size: 13, weight: .semibold))
            Text(atLimit
                 ? "Ücretsiz sınır doldu — devam için Pro"
                 : "Ücretsiz: \(count)/\(FeatureGate.freeEntryLimit) kare")
                .font(Theme.caption(12))
            Spacer()
            if atLimit {
                Text("Pro'ya Geç")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.accent)
            }
        }
        .foregroundStyle(atLimit ? theme.accent : theme.inkMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if atLimit { activeSheet = .paywall } }
    }

    private func exportProjectArchive(format: ProjectArchive.ExportFormat) {
        isExportingArchive = true
        Task {
            defer { isExportingArchive = false }
            do {
                let url = try await ProjectArchive.write(project: project, format: format)
                archiveTempURL = url
                archiveExportItem = ArchiveExportItem(url: url)
            } catch {
                archiveExportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func performPendingShareAction() {
        guard let action = pendingShareAction else { return }
        pendingShareAction = nil
        if action == .archiveFolder {
            exportProjectArchive(format: .folder)
            return
        }
        if action == .archiveSingleFile {
            exportProjectArchive(format: .singleFile)
            return
        }
        isRenderingShareCard = true
        Task {
            defer { isRenderingShareCard = false }
            let url: URL?
            switch action {
            case .streak:
                url = await renderShareCard()
            case .compare:
                url = await renderCompareCard()
            case .story:
                url = await renderStoryCard()
            case .archiveFolder, .archiveSingleFile:
                url = nil
            }
            guard let url else {
                shareCardCreationFailed = true
                return
            }
            shareCardURL = url
            activeSheet = .shareCard
        }
    }

    private func renderShareCard() async -> URL? {
        guard !liveEntries.isEmpty else { return nil }
        let heroEntry = liveEntries.reversed().first { $0.imageData != nil }
        let heroImage: UIImage?
        if let heroEntry {
            heroImage = await ImageDownsampler.cachedImage(
                key: "streak-\(heroEntry.imageCacheKey)",
                maxPixelSize: 1_400,
                load: { heroEntry.imageData }
            )
        } else {
            heroImage = nil
        }
        let dates = liveEntries.map(\.capturedAt)
        let renderer = ImageRenderer(content: StreakShareCard(
            title: project.title,
            categoryName: project.category.displayName,
            heroImage: heroImage,
            streak: ActivitySummary.streak(capturedDates: dates),
            total: dates.count,
            daysRunning: ActivitySummary.daysRunning(firstCapture: dates.first),
            theme: theme
        ))
        renderer.scale = 1
        guard let uiImage = renderer.uiImage, let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-series-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    private func renderCompareCard() async -> URL? {
        let sorted = liveEntries.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = sorted.first, let last = sorted.last, first.id != last.id else { return nil }
        guard
            let firstImage = await ImageDownsampler.cachedImage(key: "cmp-\(first.imageCacheKey)", maxPixelSize: 900, load: { first.imageData }),
            let lastImage = await ImageDownsampler.cachedImage(key: "cmp-\(last.imageCacheKey)", maxPixelSize: 900, load: { last.imageData })
        else { return nil }
        let renderer = ImageRenderer(content: CompareShareCard(
            title: project.title,
            firstImage: firstImage,
            lastImage: lastImage,
            firstDate: first.capturedAt,
            lastDate: last.capturedAt,
            theme: theme
        ))
        renderer.scale = 1
        guard let uiImage = renderer.uiImage, let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-compare-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    private func renderStoryCard() async -> URL? {
        let sorted = liveEntries.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = sorted.first, let last = sorted.last, first.id != last.id else { return nil }
        guard
            let firstImage = await ImageDownsampler.cachedImage(key: "story-\(first.imageCacheKey)", maxPixelSize: 1200, load: { first.imageData }),
            let lastImage = await ImageDownsampler.cachedImage(key: "story-\(last.imageCacheKey)", maxPixelSize: 1200, load: { last.imageData })
        else { return nil }
        let renderer = ImageRenderer(content: StoryShareCard(
            title: project.title,
            firstImage: firstImage,
            lastImage: lastImage,
            firstDate: first.capturedAt,
            lastDate: last.capturedAt,
            theme: theme
        ))
        renderer.scale = 1
        guard let uiImage = renderer.uiImage, let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-story-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    private var statsRow: some View {
        let dates = liveEntries.map(\.capturedAt)
        let streak = ActivitySummary.streak(capturedDates: dates)
        return HStack(spacing: 12) {
            StatTile(
                icon: "flame.fill",
                value: "\(streak)",
                label: "Gün serisi",
                accent: accent,
                isAlive: streak > 0
            )
            StatTile(
                icon: "photo.stack",
                value: "\(dates.count)",
                label: "Toplam kare",
                accent: accent
            )
            StatTile(
                icon: "calendar",
                value: "\(ActivitySummary.daysRunning(firstCapture: dates.first))",
                label: "Gündür sürüyor",
                accent: accent
            )
        }
    }

    private func deleteEntry(_ entry: Entry) {
        let repository = ProjectRepository(context: modelContext)
        withAnimation {
            try? repository.deleteEntry(entry)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            try? repository.saveIfNeeded()
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                LinearGradient(
                    colors: [.black.opacity(0.05), .clear, .black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(project.title)
                    .font(.system(size: 30, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text("\(liveEntries.count)")
                        .monospacedDigit().fontWeight(.semibold)
                    Text("kare · \(project.cadence.displayName)")
                }
                .font(Theme.caption(13))
                .foregroundStyle(.white.opacity(0.92))
            }
            .padding(20)
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            Label(project.category.displayName, systemImage: Theme.icon(for: project.category))
                .font(Theme.caption(12))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .liquidGlassBarCapsule()
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            if isCaptureDue {
                Text("Bugün")
                    .font(Theme.caption(12))
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.white, in: Capsule())
                    .padding(16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .task(id: liveEntries.last?.imageCacheKey) {
            guard let last = liveEntries.last else { return }
            heroImage = await ImageDownsampler.cachedImage(key: "hero-\(last.imageCacheKey)", maxPixelSize: 1000) { last.imageData }
        }
    }

    private var canExport: Bool {
        FeatureGate.canExportTimelapse(isPro: store.isPro, entryCount: liveEntries.count)
    }

    private var exportButton: some View {
        Button {
            activeSheet = canExport ? .export : .paywall
        } label: {
            Label(canExport ? "Timelapse'i Oluştur" : "Timelapse için Pro'ya geç",
                  systemImage: canExport ? "film.stack" : "lock.fill")
                .font(Theme.headline(17))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exportButton")
    }

    private var timeline: some View {
        let allEntries = displayedEntries
        let entries = showsAllTimelineEntries
            ? allEntries
            : Array(allEntries.prefix(Self.initialTimelineEntryCount))
        let hiddenEntryCount = max(0, allEntries.count - entries.count)
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isSelectingEntries ? "\(selectedEntryIDs.count) seçildi" : "Zaman Çizelgesi")
                    .font(Theme.headline(18))
                    .foregroundStyle(theme.ink)
                Spacer()
                if !isSelectingEntries {
                    Button("Seç") {
                        withAnimation(.easeInOut(duration: 0.2)) { isSelectingEntries = true }
                    }
                    .font(Theme.headline(14))
                    .foregroundStyle(accent)
                    .accessibilityIdentifier("timelineSelectButton")
                }
            }
            .padding(.bottom, 12)

            monthFilterBar
                .padding(.bottom, 18)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TimelineEntryRow(
                    entry: entry,
                    accent: accent,
                    isLast: index == entries.count - 1,
                    isSelecting: isSelectingEntries,
                    isSelected: selectedEntryIDs.contains(entry.id)
                ) {
                    if isSelectingEntries {
                        toggleSelection(entry)
                    } else {
                        activeCover = .viewer(entry)
                    }
                }
                .contextMenu {
                    if !isSelectingEntries {
                        Button {
                            DeferredMenuAction.perform {
                                isSelectingEntries = true
                                selectedEntryIDs.insert(entry.id)
                            }
                        } label: {
                            Label("Seç", systemImage: "checkmark.circle")
                        }
                    }
                    Button {
                        DeferredMenuAction.perform { activeCover = .viewer(entry) }
                    } label: {
                        Label("Görüntüle", systemImage: "eye")
                    }
                    Button(role: .destructive) {
                        DeferredMenuAction.perform { deleteEntry(entry) }
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                }
            }

            if hiddenEntryCount > 0 {
                timelineContinuation(hiddenEntryCount: hiddenEntryCount)
            }

            if lockedCount > 0 {
                lockedEntriesBanner
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func timelineContinuation(hiddenEntryCount: Int) -> some View {
        if isRevealingTimelineEntries {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(accent)
                Text("Fotoğraflar yüklenirken lütfen bekleyiniz")
                    .font(Theme.body(14))
                    .foregroundStyle(theme.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .accessibilityIdentifier("timelineLoadingMore")
        } else {
            Button(action: revealRemainingTimelineEntries) {
                HStack(spacing: 8) {
                    Text("Devamını Gör")
                    Text("(\(hiddenEntryCount))")
                        .monospacedDigit()
                        .foregroundStyle(theme.inkMuted)
                    Image(systemName: "chevron.down")
                }
                .font(Theme.headline(15))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityIdentifier("timelineLoadMoreButton")
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button(areAllDisplayedEntriesSelected ? "Temizle" : "Tümü") {
                toggleAllDisplayedEntries()
            }
            .font(Theme.headline(15))
            .foregroundStyle(accent)
            .accessibilityIdentifier("timelineSelectAllButton")

            Spacer(minLength: 8)

            Button {
                activeSheet = .batchDate
            } label: {
                Label("Tarih", systemImage: "calendar.badge.clock")
            }
            .buttonStyle(BatchMetadataButtonStyle(accent: accent))
            .disabled(selectedEntryIDs.isEmpty)
            .accessibilityIdentifier("batchDateButton")
            Button {
                activeSheet = .batchLocation
            } label: {
                Label("Konum", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(BatchMetadataButtonStyle(accent: accent))
            .disabled(selectedEntryIDs.isEmpty)
            .accessibilityIdentifier("batchLocationButton")

            Spacer(minLength: 8)

            Button("Bitti") {
                finishSelection()
            }
            .font(Theme.headline(15))
            .foregroundStyle(accent)
            .accessibilityIdentifier("timelineDoneButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func toggleSelection(_ entry: Entry) {
        if selectedEntryIDs.contains(entry.id) {
            selectedEntryIDs.remove(entry.id)
        } else {
            selectedEntryIDs.insert(entry.id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var areAllDisplayedEntriesSelected: Bool {
        !displayedEntries.isEmpty && displayedEntries.allSatisfy { selectedEntryIDs.contains($0.id) }
    }

    private func toggleAllDisplayedEntries() {
        if areAllDisplayedEntriesSelected {
            selectedEntryIDs.subtract(displayedEntries.map(\.id))
        } else {
            selectedEntryIDs.formUnion(displayedEntries.map(\.id))
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func finishSelection() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelectingEntries = false
            selectedEntryIDs.removeAll()
        }
    }

    private var lockedCount: Int {
        FeatureGate.lockedEntryCount(isPro: store.isPro, totalEntries: liveEntries.count)
    }

    private var lockedEntriesBanner: some View {
        Button {
            activeSheet = .paywall
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(lockedCount) kare kilitli")
                        .font(Theme.headline(15)).foregroundStyle(theme.ink)
                    Text("Tüm karelerine erişmek için Pro'ya geç")
                        .font(Theme.caption(12)).foregroundStyle(theme.inkMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.inkMuted)
            }
            .padding(14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    private var monthFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: String(localized: "Tümü", bundle: .appLanguage), isSelected: monthFilter == nil, accent: accent) {
                    setMonthFilter(nil)
                }
                ForEach(availableMonths, id: \.self) { key in
                    FilterChip(title: monthLabel(key), isSelected: monthFilter == key, accent: accent) {
                        setMonthFilter(key)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var accessibleEntries: [Entry] {
        let newestFirst = Array(liveEntries.reversed())
        guard lockedCount > 0 else { return newestFirst }
        return Array(newestFirst.prefix(FeatureGate.freeEntryLimit))
    }

    private var displayedEntries: [Entry] {
        guard let monthFilter else { return accessibleEntries }
        return accessibleEntries.filter { monthKey(for: $0.capturedAt) == monthFilter }
    }

    private var hiddenTimelineEntryCount: Int {
        showsAllTimelineEntries ? 0 : max(0, displayedEntries.count - Self.initialTimelineEntryCount)
    }

    private func setMonthFilter(_ filter: MonthKey?) {
        guard monthFilter != filter else { return }
        monthFilter = filter
        showsAllTimelineEntries = false
        isRevealingTimelineEntries = false
    }

    private func revealRemainingTimelineEntries() {
        guard !isRevealingTimelineEntries, hiddenTimelineEntryCount > 0 else { return }
        isRevealingTimelineEntries = true

        // İlk yeni ekran dolusunu küçük boyutta önceden hazırla. Böylece tüm arşivi
        // belleğe almadan butondan sonraki kaydırma anında akıcı kalır.
        let upcomingEntries = Array(
            displayedEntries
                .dropFirst(Self.initialTimelineEntryCount)
                .prefix(6)
        )
        let requestedFilter = monthFilter
        Task { @MainActor in
            for entry in upcomingEntries {
                guard !Task.isCancelled else { return }
                _ = await ImageDownsampler.cachedImage(
                    key: "row-\(entry.imageCacheKey)",
                    maxPixelSize: Self.timelinePreviewPixelSize
                ) { entry.imageData }
                await Task.yield()
            }
            guard !Task.isCancelled,
                  isRevealingTimelineEntries,
                  monthFilter == requestedFilter else { return }
            showsAllTimelineEntries = true
            isRevealingTimelineEntries = false
        }
    }

    private var availableMonths: [MonthKey] {
        let keys = Set(accessibleEntries.map { monthKey(for: $0.capturedAt) })
        return keys.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    private func monthKey(for date: Date) -> MonthKey {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return MonthKey(year: components.year ?? 0, month: components.month ?? 0)
    }

    private func monthLabel(_ key: MonthKey) -> String {
        var components = DateComponents()
        components.year = key.year
        components.month = key.month
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).year().locale(AppLanguage.currentLocale))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera")
                .font(.system(size: 30))
                .foregroundStyle(theme.inkMuted)
            Text("Henüz çekim yok")
                .font(Theme.headline(16))
                .foregroundStyle(theme.ink)
            Text("Sağ üstteki kamera düğmesiyle ilk çekimini ekle.")
                .font(Theme.body(14))
                .foregroundStyle(theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

private struct BatchMetadataButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline(13))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(accent.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct BatchDateEditSheet: View {
    let count: Int
    let onSave: (Date, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var preservingTime = true

    init(count: Int, initialDate: Date, onSave: @escaping (Date, Bool) -> Void) {
        self.count = count
        self.onSave = onSave
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Tarih", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    Toggle("Fotoğrafların saatlerini koru", isOn: $preservingTime)
                    if !preservingTime {
                        DatePicker("Saat", selection: $date, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text(preservingTime
                         ? "Seçilen \(count) fotoğraf aynı güne taşınır; kendi saatleri korunur."
                         : "Seçilen \(count) fotoğrafa aynı tarih ve saat uygulanır.")
                }
            }
            .navigationTitle("Tarihi Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Uygula") {
                        onSave(date, preservingTime)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BatchLocationResult: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var resolved: ResolvedLocation {
        ResolvedLocation(latitude: latitude, longitude: longitude, placeName: name)
    }
}

private struct BatchLocationEditSheet: View {
    let count: Int
    let onSave: (ResolvedLocation?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [BatchLocationResult] = []
    @State private var isSearching = false
    @State private var isLocating = false
    @State private var showLocationError = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        useCurrentLocation()
                    } label: {
                        Label {
                            Text(isLocating ? "Konum alınıyor…" : "Mevcut Konumumu Kullan")
                        } icon: {
                            if isLocating {
                                ProgressView()
                            } else {
                                Image(systemName: "location.fill")
                            }
                        }
                    }
                    .disabled(isLocating)

                    Button(role: .destructive) {
                        onSave(nil)
                        dismiss()
                    } label: {
                        Label("Konumu Kaldır", systemImage: "mappin.slash")
                    }
                }

                Section("Konum Ara") {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Şehir, semt veya yer", text: $query)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.search)
                    }
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    ForEach(results) { result in
                        Button {
                            onSave(result.resolved)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name)
                                    .foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(count) Fotoğrafın Konumu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .alert("Konum Alınamadı", isPresented: $showLocationError) {
                Button("Ayarları Aç") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Konum iznini kontrol edebilir veya yukarıdaki arama alanından bir yer seçebilirsin.")
            }
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = (response?.mapItems ?? []).prefix(12).map { item in
                let placemark = item.placemark
                let name = item.name ?? placemark.locality ?? trimmed
                let subtitle = [placemark.subLocality, placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }
                    .filter { $0 != name }
                    .joined(separator: ", ")
                return BatchLocationResult(
                    id: "\(placemark.coordinate.latitude)-\(placemark.coordinate.longitude)-\(name)",
                    name: name,
                    subtitle: subtitle,
                    latitude: placemark.coordinate.latitude,
                    longitude: placemark.coordinate.longitude
                )
            }
            isSearching = false
        }
    }

    private func useCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        Task {
            let location = await LocationService().currentLocation()
            isLocating = false
            guard let location else {
                showLocationError = true
                return
            }
            onSave(location)
            dismiss()
        }
    }
}

/// Sistem paylaşım sayfasını (UIActivityViewController) SwiftUI'da sunar — çift modu
/// davetini paylaşmak için.
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct StatTile: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey
    var accent: Color
    var isAlive: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isAlive ? accent : theme.inkMuted)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .default))
                .monospacedDigit()
                .foregroundStyle(theme.ink)
            Text(label)
                .font(Theme.caption(11))
                .foregroundStyle(theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .cardStyle()
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(13))
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? .white : theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? accent : theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TimelineEntryRow: View {
    let entry: Entry
    let accent: Color
    let isLast: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @State private var photo: UIImage?

    private let tileWidth: CGFloat = 58
    private let tileHeight: CGFloat = 66
    private let cardHeight: CGFloat = 160
    private let rowGap: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rail
            card
        }
    }

    private var lineColor: Color { theme.inkMuted.opacity(0.18) }

    private var rail: some View {
        VStack(spacing: 0) {
            calendarTile
            if !isLast {
                Rectangle()
                    .fill(lineColor)
                    .frame(width: 2, height: cardHeight + rowGap - tileHeight)
            }
        }
        .frame(width: tileWidth)
    }

    private var calendarTile: some View {
        VStack(spacing: 1) {
            Text(entry.capturedAt, format: .dateTime.weekday(.abbreviated))
                .font(Theme.caption(11))
                .fontWeight(.semibold)
                .foregroundStyle(accent)
            Text(entry.capturedAt, format: .dateTime.day())
                .font(.system(size: 24, weight: .bold, design: .default))
                .foregroundStyle(theme.ink)
            Text(entry.capturedAt, format: .dateTime.month(.abbreviated))
                .font(Theme.caption(10))
                .foregroundStyle(theme.inkMuted)
        }
        .frame(width: tileWidth, height: tileHeight)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var videoBadge: some View {
        if entry.isVideo {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.25), radius: 4)
                .allowsHitTesting(false)
        }
    }

    private var card: some View {
        Button(action: onTap) {
            ZStack {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(theme.surface)
                    Image(systemName: "camera").foregroundStyle(theme.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
            .clipped()
            .overlay(alignment: .topLeading) { locationTag }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .white)
                        .shadow(color: .black.opacity(0.35), radius: 3)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) { timeStamp }
            .overlay(alignment: .center) { videoBadge }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? accent : theme.ink.opacity(0.06), lineWidth: isSelected ? 3 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, rowGap)
        .accessibilityIdentifier("timelineCard")
        .accessibilityValue(isSelected ? Text("Seçili") : Text("Seçili değil"))
        .task(id: entry.imageCacheKey) {
            let detailed = await ImageDownsampler.cachedImage(
                key: "row-\(entry.imageCacheKey)",
                maxPixelSize: ProjectDetailView.timelinePreviewPixelSize
            ) { entry.imageData }
            guard !Task.isCancelled else { return }
            photo = detailed
            await resolvePlaceIfNeeded()
        }
    }

    @ViewBuilder
    private var locationTag: some View {
        if let place = entry.placeName, !place.isEmpty {
            Label(place, systemImage: "mappin.and.ellipse")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(7)
        }
    }

    private var timeStamp: some View {
        Label(entry.capturedAt.formatted(.dateTime.hour().minute().locale(AppLanguage.currentLocale)), systemImage: "clock.fill")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(7)
    }

    private func resolvePlaceIfNeeded() async {
        guard entry.placeName == nil, let latitude = entry.latitude, let longitude = entry.longitude else { return }
        let name = await LocationService.reverseGeocode(CLLocation(latitude: latitude, longitude: longitude))
        guard let name else { return }
        entry.placeName = name
    }
}

#Preview {
    let container = AppModelContainer.makeInMemory()
    let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
    container.mainContext.insert(project)
    for dayOffset in 0..<5 {
        let entry = Entry(capturedAt: .now.addingTimeInterval(Double(-dayOffset) * 86_400))
        entry.project = project
        container.mainContext.insert(entry)
    }
    return NavigationStack {
        ProjectDetailView(project: project)
    }
    .modelContainer(container)
    .environment(StoreService())
}
