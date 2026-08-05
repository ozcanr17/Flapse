@preconcurrency import ActivityKit
import Foundation

struct RenderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var isFinished: Bool
    }

    var title: String
}

@MainActor
enum RenderActivityCenter {

    private static var activities: [UUID: Activity<RenderActivityAttributes>] = [:]

    static func start(id: UUID, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[id] == nil else { return }
        let state = RenderActivityAttributes.ContentState(progress: 0, isFinished: false)
        activities[id] = try? Activity.request(
            attributes: RenderActivityAttributes(title: title),
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    static func update(id: UUID, progress: Double) {
        guard let activity = activities[id] else { return }
        let state = RenderActivityAttributes.ContentState(progress: min(max(progress, 0), 1), isFinished: false)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    static func finish(id: UUID, success: Bool) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        Task {
            if success {
                let state = RenderActivityAttributes.ContentState(progress: 1, isFinished: true)
                let content = ActivityContent(state: state, staleDate: nil)
                await activity.update(
                    content,
                    alertConfiguration: AlertConfiguration(
                        title: "\(String(localized: "Timelapse hazır", bundle: .appLanguage))",
                        body: "\(String(localized: "Videon oluşturuldu, kaydetmeyi unutma.", bundle: .appLanguage))",
                        sound: .default
                    )
                )
                try? await Task.sleep(for: .seconds(3))
                await activity.end(content, dismissalPolicy: .after(.now + 60 * 10))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
