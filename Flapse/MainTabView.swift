import SwiftUI
import SwiftData

extension EnvironmentValues {
    @Entry var customTabBarHidden: Binding<Bool> = .constant(false)
}

struct MainTabView: View {

    enum Tab: Hashable {
        case home, projects, saved, settings
    }

    @State private var tab: Tab = .home
    @Environment(StoreService.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @State private var captureProjects: [Project] = []

    @State private var showQuickPick = false
    @State private var showAddProject = false
    @State private var pendingCapture: Project?
    @State private var captureRoute: CaptureRoute?
    @State private var showPaywall = false
    @State private var previewIndex: Int?
    @State private var itemFrames: [Int: CGRect] = [:]
    @State private var highlightX: CGFloat = 0
    @State private var highlightWidth: CGFloat = 0
    @State private var isDraggingBar = false
    @State private var projectsPath = NavigationPath()
    @State private var isCustomTabBarHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barTint = Color(light: "F5F5F7", dark: "1B1B1F").opacity(0.26)

    private enum CaptureRoute: Identifiable {
        case project(Project)
        case auto
        var id: String {
            switch self {
            case .project(let project): project.id.uuidString
            case .auto: "auto"
            }
        }
    }

    private var activeProjects: [Project] {
        captureProjects.filter { !$0.isDeleted && $0.deletedAt == nil }
    }

    private var liveProjects: [Project] {
        activeProjects.filter { !$0.isHidden }
    }

    private var unlockedProjectID: UUID? {
        FeatureGate.unlockedProjectID(
            isPro: store.isPro,
            projects: activeProjects.map { (id: $0.id, createdAt: $0.createdAt) }
        )
    }

    private var capturableProjects: [Project] {
        guard !store.isPro else { return liveProjects }
        return liveProjects.filter { $0.id == unlockedProjectID }
    }

    var body: some View {
        ZStack {
            theme.canvas.ignoresSafeArea()
            TabView(selection: $tab) {
                pane {
                    HomeView(
                        isActive: tab == .home,
                        onCapture: beginCapture,
                        onShowProjects: { activate(barItems[1]) }
                    )
                }
                .tag(Tab.home)

                projectsPane
                    .tag(Tab.projects)

                pane { SavedTimelapsesView() }
                    .tag(Tab.saved)

                pane { SettingsView(onWelcomeFinished: { selectTab(.home) }) }
                    .tag(Tab.settings)
            }
            .toolbar(.hidden, for: .tabBar)
        }
        .environment(\.customTabBarHidden, $isCustomTabBarHidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isCustomTabBarHidden {
                tabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isCustomTabBarHidden)
        .sheet(isPresented: $showQuickPick, onDismiss: presentPendingCapture) {
            QuickCaptureSheet(projects: capturableProjects) { project in
                pendingCapture = project
                showQuickPick = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddProject, onDismiss: presentPendingCapture) {
            AddProjectSheet(repository: ProjectRepository(context: modelContext)) { project in
                refreshCaptureProjects()
                pendingCapture = project
            }
        }
        .fullScreenCover(item: $captureRoute) { route in
            switch route {
            case .project(let project):
                CameraCaptureView(project: project)
            case .auto:
                AutoCaptureFlow(projects: capturableProjects)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store)
        }
        .onOpenURL { url in
            guard url.scheme == "flapse", url.host == "capture" else { return }
            captureRoute = nil
            refreshCaptureProjects()
            if let due = capturableProjects.first(where: { $0.isCaptureDue() }) {
                let count = liveEntryCount(in: due)
                if FeatureGate.canAddEntry(isPro: store.isPro, currentEntryCount: count) {
                    CameraService.shared.prewarm(position: CameraCaptureViewModel.initialPosition(for: due.category))
                    captureRoute = .project(due)
                } else {
                    showPaywall = true
                }
            } else {
                captureTapped()
            }
        }
    }

    private func pane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .contentMargins(.bottom, 40, for: .scrollContent)
    }

    private var projectsPane: some View {
        NavigationStack(path: $projectsPath) {
            ProjectListView(isActive: tab == .projects && !isCustomTabBarHidden)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .contentMargins(.bottom, 40, for: .scrollContent)
    }

    private struct BarItem {
        let tab: Tab?
        let icon: String
        let activeIcon: String
        let label: LocalizedStringKey
        let identifier: String
    }

    private var barItems: [BarItem] {
        [
            BarItem(tab: .home, icon: "house", activeIcon: "house.fill", label: "Ana Sayfa", identifier: "homeTab"),
            BarItem(tab: .projects, icon: "square.grid.2x2", activeIcon: "square.grid.2x2.fill", label: "Projeler", identifier: "projectsTab"),
            BarItem(tab: nil, icon: "camera.fill", activeIcon: "camera.fill", label: "Kare çek", identifier: "homeCaptureButton"),
            BarItem(tab: .saved, icon: "film.stack", activeIcon: "film.stack.fill", label: "Kaydedilenler", identifier: "savedTab"),
            BarItem(tab: .settings, icon: "gearshape", activeIcon: "gearshape.fill", label: "Ayarlar", identifier: "settingsButton")
        ]
    }

    private struct ItemFramePreference: PreferenceKey {
        static let defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    @ViewBuilder
    private var tabBar: some View {
        tabBarContent
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .offset(y: 12)
    }

    private var tabBarContent: some View {
        iconRow(reportsFrames: true)
            .coordinateSpace(name: "tabBarSpace")
            // Önceki, daha belirgin Liquid Glass görünümü: sistem materyali
            // temaya uyumlu çok hafif bir tint ile arka planı kırar.
            .liquidGlassCapsule(tint: Self.barTint, interactive: true)
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.34), theme.ink.opacity(0.08), .white.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if highlightWidth > 0 {
                    Capsule()
                        .fill(theme.accent.opacity(0.12))
                        .frame(width: highlightWidth, height: 46)
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                        }
                        .offset(x: highlightX, y: 6)
                        .animation(
                            reduceMotion ? nil :
                                isDraggingBar
                                ? .interactiveSpring(response: 0.12, dampingFraction: 0.9)
                                : .easeOut(duration: 0.08),
                            value: highlightX
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
        .onPreferenceChange(ItemFramePreference.self) { frames in
            guard itemFrames != frames else { return }
            itemFrames = frames
            if !isDraggingBar, let frame = frames[currentIndex] {
                highlightX = frame.minX
                highlightWidth = frame.width
            }
        }
        .onChange(of: tab) {
            guard !isDraggingBar, let frame = itemFrames[currentIndex] else { return }
            highlightX = frame.minX
            highlightWidth = frame.width
        }
        .simultaneousGesture(slideToSelect)
        .sensoryFeedback(.selection, trigger: previewIndex)
        .sensoryFeedback(.impact(weight: .light), trigger: tab)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: previewIndex)
        .accessibilityElement(children: .contain)
    }

    private var currentIndex: Int {
        barItems.firstIndex { $0.tab == tab } ?? 0
    }

    private var slideToSelect: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("tabBarSpace"))
            .onChanged { value in
                isDraggingBar = true
                let index = itemIndex(at: value.location.x)
                guard previewIndex != index else { return }
                previewIndex = index
                if let frame = itemFrames[index] {
                    highlightWidth = frame.width
                    highlightX = frame.minX
                }
            }
            .onEnded { value in
                let index = itemIndex(at: value.location.x)
                previewIndex = nil
                isDraggingBar = false
                let item = barItems[index]
                let restingIndex = item.tab == nil ? currentIndex : index
                if let frame = itemFrames[restingIndex] {
                    highlightX = frame.minX
                    highlightWidth = frame.width
                }
                activate(item)
            }
    }

    private func itemIndex(at x: CGFloat) -> Int {
        guard !itemFrames.isEmpty else { return 0 }
        let nearest = itemFrames.min { lhs, rhs in
            abs(lhs.value.midX - x) < abs(rhs.value.midX - x)
        }
        return nearest?.key ?? 0
    }

    private func activate(_ item: BarItem) {
        if let target = item.tab {
            if target == .projects && tab == .projects {
                projectsPath = NavigationPath()
            }
            selectTab(target)
            if let index = barItems.firstIndex(where: { $0.identifier == item.identifier }),
               let frame = itemFrames[index] {
                highlightX = frame.minX
                highlightWidth = frame.width
            }
        } else {
            captureTapped()
        }
    }

    private func selectTab(_ target: Tab) {
        guard target != tab else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tab = target
        }
    }

    private func iconRow(reportsFrames: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(barItems.enumerated()), id: \.element.identifier) { index, item in
                barItemView(item, index: index, reportsFrame: reportsFrames)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func barItemView(_ item: BarItem, index: Int, reportsFrame: Bool = true) -> some View {
        let isCamera = item.tab == nil
        let isActive = item.tab != nil && item.tab == tab
        let isPreviewed = previewIndex == index

        let icon = Image(systemName: isActive || isCamera ? item.activeIcon : item.icon)
            .font(.system(size: isCamera ? 23 : 21, weight: isCamera ? .semibold : .medium))
            .foregroundStyle(isActive ? theme.accent : theme.ink.opacity(isCamera ? 0.78 : 0.62))
            .shadow(color: theme.surface.opacity(0.8), radius: 1, x: 0, y: 0.5)
            .frame(maxWidth: .infinity, minHeight: 46)
            .scaleEffect(isPreviewed && !reduceMotion ? 1.08 : 1)
            .background {
                if reportsFrame {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ItemFramePreference.self,
                            value: [index: proxy.frame(in: .named("tabBarSpace"))]
                        )
                    }
                }
            }

        if reportsFrame {
            Button {
                activate(item)
            } label: {
                icon
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item.identifier)
                .accessibilityLabel(Text(item.label))
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        } else {
            icon
                .accessibilityHidden(true)
        }
    }

    private func captureTapped() {
        refreshCaptureProjects()
        guard !liveProjects.isEmpty else {
            showAddProject = true
            return
        }
        CameraService.shared.prewarm()
        if store.isPro {
            captureRoute = .auto
        } else {
            showQuickPick = true
        }
    }

    private func beginCapture(_ project: Project) {
        let count = liveEntryCount(in: project)
        if FeatureGate.canAddEntry(isPro: store.isPro, currentEntryCount: count) {
            CameraService.shared.prewarm(position: CameraCaptureViewModel.initialPosition(for: project.category))
            captureRoute = .project(project)
        } else {
            showPaywall = true
        }
    }

    private func presentPendingCapture() {
        guard let project = pendingCapture else {
            CameraService.shared.stop()
            return
        }
        pendingCapture = nil
        let count = liveEntryCount(in: project)
        if FeatureGate.canAddEntry(isPro: store.isPro, currentEntryCount: count) {
            CameraService.shared.prewarm(position: CameraCaptureViewModel.initialPosition(for: project.category))
            captureRoute = .project(project)
        } else {
            CameraService.shared.stop()
            showPaywall = true
        }
    }

    private func refreshCaptureProjects() {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\Project.createdAt, order: .reverse)]
        )
        captureProjects = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func liveEntryCount(in project: Project) -> Int {
        (project.entries ?? []).lazy.filter { !$0.isDeleted && $0.deletedAt == nil }.count
    }
}

struct QuickCaptureSheet: View {
    let projects: [Project]
    let onSelect: (Project) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { project in
                    let accent = Theme.accent(for: project.category)
                    Button {
                        CameraService.shared.prewarm(
                            position: CameraCaptureViewModel.initialPosition(for: project.category)
                        )
                        onSelect(project)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(accent.opacity(0.15)).frame(width: 44, height: 44)
                                Image(systemName: Theme.icon(for: project.category))
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.title).font(Theme.headline(16)).foregroundStyle(theme.ink)
                                Text("\((project.entries ?? []).lazy.filter { !$0.isDeleted && $0.deletedAt == nil }.count) kare")
                                    .font(Theme.caption(12)).foregroundStyle(theme.inkMuted)
                            }
                            Spacer()
                            if project.isCaptureDue() {
                                Text("Bugün")
                                    .font(Theme.caption(11)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(accent, in: Capsule())
                            }
                            Image(systemName: "camera.fill").foregroundStyle(accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                }
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

#Preview {
    MainTabView()
        .modelContainer(AppModelContainer.makeInMemory())
        .environment(StoreService())
}
