import SwiftUI
import SwiftData
import UIKit

private struct ProjectCardSnapshot {
    let lastEntry: Entry?
    let count: Int
    let streak: Int

    var lastCaptureDate: Date? { lastEntry?.capturedAt }

    static func grouped(entries: [Entry]) -> [UUID: ProjectCardSnapshot] {
        struct Accumulator {
            var lastEntry: Entry?
            var dates: [Date] = []
        }

        var grouped: [UUID: Accumulator] = [:]
        grouped.reserveCapacity(min(entries.count, 64))
        for entry in entries {
            guard let projectID = entry.project?.id else { continue }
            grouped[projectID, default: Accumulator()].dates.append(entry.capturedAt)
            if grouped[projectID]?.lastEntry?.capturedAt ?? .distantPast < entry.capturedAt {
                grouped[projectID]?.lastEntry = entry
            }
        }
        return grouped.mapValues { value in
            ProjectCardSnapshot(
                lastEntry: value.lastEntry,
                count: value.dates.count,
                streak: ActivitySummary.streak(capturedDates: value.dates)
            )
        }
    }
}

/// Projeleri listeleyen ana ekran.
struct ProjectListView: View {

    let isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.createdAt, order: .reverse)
    private var projects: [Project]
    @Query(filter: #Predicate<Entry> {
        $0.deletedAt == nil && $0.project?.deletedAt == nil
    }, sort: \Entry.capturedAt, order: .reverse)
    private var liveEntries: [Entry]
    @Environment(\.modelContext) private var modelContext
    @Environment(StoreService.self) private var store
    @Environment(\.theme) private var theme

    @State private var activeSheet: ActiveSheet?
    @State private var pendingAfterSignIn: ActiveSheet?
    @AppStorage("auth.gateSkipped") private var signInGateSkipped = false
    @State private var pendingDeletion: [Project] = []
    @State private var resumeExportProject: Project?
    @State private var checkedJobID: UUID?

    private var renderService: TimelapseRenderService { TimelapseRenderService.shared }

    private enum ActiveSheet: Identifiable {
        case addProject
        case importNew
        case paywall
        case signIn
        var id: Int { hashValue }
    }

    private var activeProjectCount: Int {
        projects.lazy.filter { !$0.isDeleted && $0.deletedAt == nil }.count
    }

    private func isLocked(_ project: Project, unlockedProjectID: UUID?) -> Bool {
        guard !store.isPro else { return false }
        return project.id != unlockedProjectID
    }

    var body: some View {
        // Bütün ilişkileri her proje kartında yeniden dolaşmak, P proje ve E kare
        // için aynı E kayıtlarını tekrar tekrar işliyordu. Tek geçişlik özet hem
        // sıralamayı hem kartları besler; fotoğraf baytlarına dokunmaz.
        let snapshots = ProjectCardSnapshot.grouped(entries: liveEntries)
        let sortedProjects = projects
            .filter { !$0.isDeleted && $0.deletedAt == nil }
            .sorted { lhs, rhs in
                let lhsActivity = snapshots[lhs.id]?.lastCaptureDate ?? lhs.createdAt
                let rhsActivity = snapshots[rhs.id]?.lastCaptureDate ?? rhs.createdAt
                return lhsActivity == rhsActivity
                    ? lhs.createdAt > rhs.createdAt
                    : lhsActivity > rhsActivity
            }
        let visibleProjects = sortedProjects.filter { !$0.isHidden }
        let unlockedID = FeatureGate.unlockedProjectID(
            isPro: store.isPro,
            projects: sortedProjects.map { (id: $0.id, createdAt: $0.createdAt) }
        )
        let jobs = visibleJobs(projectIDs: Set(visibleProjects.map(\.id)))
        ZStack {
            theme.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .background(alignment: .top) { ScrollEdgeFade(height: 130) }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

            if visibleProjects.isEmpty && jobs.isEmpty {
                EmptyProjectsView(onCreate: addProjectTapped, onImport: importTapped)
            } else {
                List {
                    ForEach(jobs) { job in
                        Button {
                            openJob(job)
                        } label: {
                            exportJobRow(job)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    ForEach(visibleProjects) { project in
                        ProjectCard(
                            project: project,
                            snapshot: snapshots[project.id] ?? ProjectCardSnapshot(lastEntry: nil, count: 0, streak: 0),
                            isActive: isActive
                        )
                                .overlay {
                                    if isLocked(project, unlockedProjectID: unlockedID) {
                                        Button {
                                            activeSheet = .paywall
                                        } label: {
                                            ZStack {
                                                Color.black.opacity(0.45)
                                                VStack(spacing: 8) {
                                                    Image(systemName: "lock.fill")
                                                        .font(.system(size: 26, weight: .semibold))
                                                    Text("Pro ile aç")
                                                        .font(Theme.headline(15))
                                                }
                                                .foregroundStyle(.white)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    } else {
                                        // Değer tabanlı gezinme: hedef ekran ancak
                                        // gerçekten girildiğinde kurulur. Kapanış
                                        // biçimindeki `NavigationLink { ... }` hedefi
                                        // ÖNDEN inşa ediyordu — ölçümde her sekme
                                        // geçişinde proje sayısı kadar `ProjectDetailView`
                                        // kuruluyor ve geçiş ~130 ms sürüyordu.
                                        NavigationLink(value: project) {
                                            Color.clear
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .opacity(0)
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        DeferredMenuAction.perform {
                                            try? ProjectRepository(context: modelContext).setHidden(true, for: project)
                                        }
                                    } label: {
                                        Label("Gizle", systemImage: "eye.slash")
                                    }
                                    Button(role: .destructive) {
                                        DeferredMenuAction.perform { pendingDeletion = [project] }
                                    } label: {
                                        Label("Sil", systemImage: "trash")
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("projectCard-\(project.title)")
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .onDelete { offsets in
                        pendingDeletion = offsets.compactMap { index in
                            visibleProjects.indices.contains(index) ? visibleProjects[index] : nil
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            }
        }
        // Ana ekranla aynı desen: gezinme çubuğu tamamen gizli, başlık ve sağdaki
        // düğmeler tek satırda, içeriğin en üstünde.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Project.self) { project in
            let _ = PerfTrace.begin("project-\(project.id.uuidString.prefix(8))", detail: "detay açılıyor")
            ProjectDetailView(project: project)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addProject:
                AddProjectSheet(repository: ProjectRepository(context: modelContext))
            case .importNew:
                PhotoImportSheet(
                    mode: .newProject,
                    repository: ProjectRepository(context: modelContext),
                    maxSelection: store.isPro ? nil : FeatureGate.freeEntryLimit,
                    onFinished: { _ in activeSheet = nil }
                )
            case .paywall:
                PaywallView(store: store)
            case .signIn:
                SignInGateSheet {
                    continuePendingAction()
                } onSkip: {
                    signInGateSkipped = true
                    continuePendingAction()
                }
            }
        }
        .confirmationDialog(
            "Proje ve içindeki tüm çekimler kalıcı olarak silinsin mi?",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) { confirmDeletion() }
            Button("Vazgeç", role: .cancel) { pendingDeletion = [] }
        }
        .sheet(item: $resumeExportProject, onDismiss: discardCheckedJob) { project in
            TimelapseExportSheet(project: project)
        }
    }

    /// Başlık ve sağdaki düğmeler aynı satırda — ana ekrandaki karşılama yazısıyla
    /// aynı dikey konumda.
    private var pageHeader: some View {
        HStack(alignment: .center) {
            Text("Projeler")
                .font(.largeTitle.bold())
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                importButton
                addButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlassBarCapsule()
        }
    }

    private var importButton: some View {
        Button {
            importTapped()
        } label: {
            toolbarIcon("photo.on.rectangle.angled")
        }
        .accessibilityIdentifier("importProjectButton")
        .accessibilityLabel(Text("Fotoğraflardan proje oluştur"))
    }

    private var addButton: some View {
        Button {
            addProjectTapped()
        } label: {
            toolbarIcon("plus")
        }
        .accessibilityIdentifier("addProjectButton")
        .accessibilityLabel(Text("Yeni proje"))
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(theme.accent)
            .frame(width: 23, height: 23)
            .frame(width: 35, height: 35, alignment: .center)
    }

    private func visibleJobs(projectIDs: Set<UUID>) -> [TimelapseRenderService.Job] {
        (renderService.activeJobs + renderService.finishedJobs)
            .filter { projectIDs.contains($0.id) }
    }

    private func openJob(_ job: TimelapseRenderService.Job) {
        guard let project = projects.first(where: { $0.id == job.id }) else { return }
        checkedJobID = job.id
        resumeExportProject = project
    }

    private func discardCheckedJob() {
        guard let id = checkedJobID else { return }
        checkedJobID = nil
        let isFinished = renderService.finishedJobs.contains { $0.id == id }
        if isFinished {
            renderService.discard(projectID: id)
        }
    }

    private func exportJobRow(_ job: TimelapseRenderService.Job) -> some View {
        HStack(spacing: 12) {
            if job.viewModel.phase == .rendering {
                ProgressView().tint(theme.accent)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(Theme.headline(15))
                    .foregroundStyle(theme.ink)
                Text(job.viewModel.phase == .rendering ? "Timelapse oluşturuluyor…" : "Timelapse hazır, dokun")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
        }
        .padding(14)
        .liquidGlassStyle(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("resumeExportBanner-\(job.title)")
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )
    }

    private func confirmDeletion() {
        let repository = ProjectRepository(context: modelContext)
        let toDelete = pendingDeletion
        pendingDeletion = []
        withAnimation {
            for project in toDelete where !project.isDeleted {
                try? repository.softDeleteProject(project)
            }
        }
    }

    private func continuePendingAction() {
        let next = pendingAfterSignIn
        pendingAfterSignIn = nil
        guard let next else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            switch next {
            case .addProject: addProjectTapped()
            case .importNew: importTapped()
            default: break
            }
        }
    }

    private func addProjectTapped() {
        guard AuthService.isSignedInNow || signInGateSkipped else {
            pendingAfterSignIn = .addProject
            activeSheet = .signIn
            return
        }
        if FeatureGate.canCreateProject(isPro: store.isPro, currentProjectCount: activeProjectCount) {
            activeSheet = .addProject
        } else {
            activeSheet = .paywall
        }
    }

    private func importTapped() {
        guard AuthService.isSignedInNow || signInGateSkipped else {
            pendingAfterSignIn = .importNew
            activeSheet = .signIn
            return
        }
        if store.isPro || FeatureGate.canCreateProject(isPro: false, currentProjectCount: activeProjectCount) {
            activeSheet = .importNew
        } else {
            activeSheet = .paywall
        }
    }

}

/// Büyük foto-kahraman kartı: projenin son karesi arka plan olur; üstüne okunabilirlik
/// için koyu geçiş, başlık ve ilerleme biner. Fotoğraf yoksa kategori rengine düşer.
private struct ProjectCard: View {
    let project: Project
    let snapshot: ProjectCardSnapshot
    let isActive: Bool

    @Environment(\.theme) private var theme
    @State private var photo: UIImage?

    private var accent: Color { Theme.accent(for: project.category) }

    var body: some View {
        let last = snapshot.lastEntry
        let count = snapshot.count
        let streak = snapshot.streak
        let isDue = project.cadence.isCaptureDue(lastCapture: last?.capturedAt)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: Theme.icon(for: project.category))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.28), in: Circle())
                Spacer()
                if streak > 0 {
                    streakBadge(streak)
                }
                if isDue {
                    Text("Bugün")
                        .font(Theme.caption(12))
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.white, in: Capsule())
                }
            }

            Spacer(minLength: 12)

            Text(project.title)
                .font(.system(size: 24, weight: .bold, design: .default))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Text("\(count)")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Text("kare · \(project.cadence.displayName)")
            }
            .font(Theme.caption(13))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.top, 3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 188)
        .background {
            ZStack {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                LinearGradient(
                    colors: [.black.opacity(0.25), .clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        .overlay {
            if streak > 0 {
                FireStreakBorder(cornerRadius: 24, isActive: isActive)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .task(id: "\(last?.imageCacheKey ?? "empty")-\(isActive)") {
            guard isActive, let last else { return }
            photo = await ImageDownsampler.cachedImage(
                key: "card-\(last.imageCacheKey)",
                maxPixelSize: 640
            ) { last.imageData }
        }
    }

    private func streakBadge(_ streak: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill").font(.system(size: 11, weight: .semibold))
            Text("\(streak)").font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
    }
}

/// Sürekli dönen bir kenarlık — `repeatForever` ile animasyonlanan bir açı yerine
/// `TimelineView` kullanır: her kare açıyı doğrudan mutlak zamandan hesaplar, bu
/// yüzden görünüm bir süre arka planda/ekran dışında kalıp geri geldiğinde
/// "biriken" animasyonu bir anda tüketip hızlı dönmez — o anki doğru açıyı gösterir.
private struct FireStreakBorder: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 4.0

    private static let gradientColors: [Color] = [
        Color(red: 1.0, green: 0.32, blue: 0.09),
        Color(red: 1.0, green: 0.62, blue: 0.05),
        Color(red: 1.0, green: 0.84, blue: 0.15),
        Color(red: 1.0, green: 0.62, blue: 0.05),
        Color(red: 1.0, green: 0.32, blue: 0.09)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { timeline in
            let angle = Self.angle(at: timeline.date)
            let gradient = AngularGradient(
                colors: Self.gradientColors,
                center: .center,
                startAngle: .degrees(angle),
                endAngle: .degrees(angle + 360)
            )
            ZStack {
                // Kenarlığın hemen altında yumuşak, bulanık bir eş — alevin canlı
                // ama soğuk-neon değil, sıcak bir parıltıyla nefes almasını sağlar.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 5)
                    .blur(radius: 4)
                    .opacity(0.55)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
    }

    private static func angle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return (t / period) * 360
    }
}

private struct EmptyProjectsView: View {
    let onCreate: () -> Void
    let onImport: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(theme.accent.opacity(0.12))
                .frame(width: 108, height: 108)
                .overlay(
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 46, weight: .regular))
                        .foregroundStyle(theme.accent)
                )

            VStack(spacing: 8) {
                Text("İlk hikayeni başlat")
                    .font(.system(size: 26, weight: .bold, design: .default))
                    .foregroundStyle(theme.ink)
                Text("Günde bir kare çek; zamanla değişimin\nkendiliğinden bir timelapse'e dönüşsün.")
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button(action: onCreate) {
                Label("Yeni Proje", systemImage: "plus")
                    .font(Theme.headline(17))
            }
            .buttonStyle(.flapsePrimary)
            .frame(maxWidth: 260)
            .padding(.top, 4)

            Button(action: onImport) {
                Label("Fotoğraflardan proje oluştur", systemImage: "photo.on.rectangle.angled")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(theme.accent)
            .frame(minHeight: 44)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

#Preview {
    NavigationStack {
        ProjectListView()
    }
    .modelContainer(AppModelContainer.makeInMemory())
    .environment(StoreService())
}
