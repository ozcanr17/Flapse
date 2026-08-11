import SwiftUI
import SwiftData

@main
struct FlapseApp: App {

    @UIApplicationDelegateAdaptor(FlapseAppDelegate.self) private var appDelegate

    let container: ModelContainer
    let storageFailureDescription: String?

    init() {
        LanguageOverrideBundle.activate()
        CloudBackupPreference.prepareForLaunch()
        #if DEBUG
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitests")
            || ProcessInfo.processInfo.environment["FLAPSE_UI_TESTS"] == "1"
        if isUITesting {
            container = AppModelContainer.makeInMemory()
            storageFailureDescription = nil
        } else {
            let result = AppModelContainer.makeProduction()
            container = result.container
            storageFailureDescription = result.failureDescription
        }
        #else
        // Release builds compile only the production store path; UI-test launch
        // arguments cannot expose an in-memory data-store bypass.
        let result = AppModelContainer.makeProduction()
        container = result.container
        storageFailureDescription = result.failureDescription
        #endif
    }

    @State private var store = StoreService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let storageFailureDescription {
                    StorageFailureView(errorDescription: storageFailureDescription)
                } else {
                    ContentView()
                }
            }
                .environment(store)
                .task {
                    guard storageFailureDescription == nil else { return }
                    await store.loadProducts()
                    await store.refreshEntitlements()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                let projects = (try? container.mainContext.fetch(FetchDescriptor<Project>())) ?? []
                ReminderScheduler.shared.sync(projects: projects)
                WidgetStateWriter.update(projects: projects)
            } else if phase == .active {
                NotificationCenter.default.post(name: .flapseCloudKitChanged, object: nil)
            }
        }
    }

}

private struct StorageFailureView: View {
    let errorDescription: String

    var body: some View {
        ContentUnavailableView {
            Label("Hata", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Beklenmeyen bir hata oluştu: \(errorDescription)")
        } actions: {
            Link(destination: LegalLinks.support) {
                Label("Bildir", systemImage: "questionmark.bubble")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
