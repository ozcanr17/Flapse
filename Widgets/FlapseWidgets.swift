import SwiftUI
import UIKit
import WidgetKit

private let flapseAccent = Color(red: 0.18, green: 0.55, blue: 0.34)
private let captureURL = URL(string: "flapse://capture")

struct FlapseWidgetEntry: TimelineEntry {
    let date: Date
    let streak: Int
    let capturedToday: Bool
    let dueCount: Int
    let totalCaptures: Int
    let activeProjectCount: Int
    let projects: [(title: String, image: UIImage?)]
    let recentDayCounts: [Int]
}

struct FlapseProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlapseWidgetEntry {
        FlapseWidgetEntry(
            date: .now,
            streak: 12,
            capturedToday: false,
            dueCount: 1,
            totalCaptures: 184,
            activeProjectCount: 4,
            projects: [
                (String(localized: "Flapse"), nil),
                (String(localized: "Projeler"), nil)
            ],
            recentDayCounts: [0, 1, 1, 0, 2, 1, 1]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FlapseWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlapseWidgetEntry>) -> Void) {
        let refresh = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 5),
            matchingPolicy: .nextTime
        ) ?? Date.now.addingTimeInterval(1800)
        completion(Timeline(entries: [currentEntry()], policy: .after(refresh)))
    }

    private func currentEntry() -> FlapseWidgetEntry {
        let defaults = WidgetStore.suite
        let titles = defaults?.stringArray(forKey: "widget.projectTitles") ?? []
        return FlapseWidgetEntry(
            date: .now,
            streak: defaults?.integer(forKey: "widget.streak") ?? 0,
            capturedToday: defaults?.bool(forKey: "widget.capturedToday") ?? false,
            dueCount: defaults?.integer(forKey: "widget.dueCount") ?? 0,
            totalCaptures: defaults?.integer(forKey: "widget.totalCaptures") ?? 0,
            activeProjectCount: defaults?.integer(forKey: "widget.activeProjectCount") ?? 0,
            projects: titles.enumerated().map { index, title in
                (title, WidgetStore.image("project-\(index).jpg"))
            },
            recentDayCounts: defaults?.array(forKey: "widget.recentDayCounts") as? [Int] ?? Array(repeating: 0, count: 7)
        )
    }
}

enum WidgetStore {
    static var suite: UserDefaults? {
        UserDefaults(suiteName: "group.rozcan.Flapse")
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.rozcan.Flapse")?
            .appendingPathComponent("widget", isDirectory: true)
    }

    static func image(_ name: String) -> UIImage? {
        guard let directory else { return nil }
        return UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }
}

private struct WidgetCanvas: View {
    var body: some View {
        Color(uiColor: .secondarySystemBackground)
    }
}

private struct FlapseMark: View {
    var foreground: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.aperture")
                .font(.caption.weight(.semibold))
                .foregroundStyle(flapseAccent)
            Text("Flapse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
        }
    }
}

private struct StatusLabel: View {
    let entry: FlapseWidgetEntry

    var body: some View {
        Label(statusText, systemImage: entry.capturedToday ? "checkmark.circle.fill" : "camera.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(entry.capturedToday ? flapseAccent : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
    }

    private var statusText: String {
        if entry.capturedToday { return String(localized: "Bugün çekildi") }
        if entry.dueCount > 0 { return String(localized: "Bugün \(entry.dueCount) çekim") }
        return String(localized: "Bugün için tamam")
    }
}

private struct ProjectArtwork: View {
    let project: (title: String, image: UIImage?)?
    var titleVisible = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = project?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if titleVisible, let title = project?.title {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(10)
            }
        }
        .clipped()
    }
}

struct FocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FlapseWidgetEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                medium
            } else {
                small
            }
        }
        .widgetURL(captureURL)
        .containerBackground(for: .widget) { WidgetCanvas() }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FlapseMark()
                Spacer()
                Image(systemName: entry.capturedToday ? "checkmark.circle.fill" : "camera.circle.fill")
                    .font(.title3)
                    .foregroundStyle(entry.capturedToday ? flapseAccent : .secondary)
            }
            Spacer(minLength: 0)
            Text("\(entry.streak)")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .monospacedDigit()
            Text("gün serisi")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            StatusLabel(entry: entry)
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ProjectArtwork(project: entry.projects.first)
                .frame(width: 144)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                FlapseMark()
                Spacer(minLength: 4)
                Text("\(entry.streak)")
                    .font(.system(.title, design: .default, weight: .bold))
                    .monospacedDigit()
                Text("gün serisi")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                StatusLabel(entry: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FlapseFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlapseFocusWidgetV2", provider: FlapseProvider()) { entry in
            FocusWidgetView(entry: entry)
        }
        .configurationDisplayName("Flapse")
        .description("Gün serin ve bugünün çekim durumu.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct JourneyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FlapseWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projeler")
                        .font(.headline)
                    Text("\(entry.activeProjectCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                StatusLabel(entry: entry)
            }
            if family == .systemLarge {
                largeMosaic
            } else {
                mediumStrip
            }
        }
        .widgetURL(captureURL)
        .containerBackground(for: .widget) { WidgetCanvas() }
    }

    private var mediumStrip: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                ProjectArtwork(project: project(at: index))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var largeMosaic: some View {
        HStack(spacing: 10) {
            ProjectArtwork(project: project(at: 0))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 10) {
                ForEach(1..<4, id: \.self) { index in
                    ProjectArtwork(project: project(at: index))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(width: 122)
        }
    }

    private func project(at index: Int) -> (title: String, image: UIImage?)? {
        guard entry.projects.indices.contains(index) else { return nil }
        return entry.projects[index]
    }
}

struct FlapseJourneyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlapseJourneyWidgetV2", provider: FlapseProvider()) { entry in
            JourneyWidgetView(entry: entry)
        }
        .configurationDisplayName("Projeler")
        .description("Projelerinin son kareleri.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RhythmWidgetView: View {
    let entry: FlapseWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aktivite")
                    .font(.headline)
                Spacer()
                Image(systemName: "flame.fill")
                    .foregroundStyle(flapseAccent)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(Array(entry.recentDayCounts.prefix(7).reversed().enumerated()), id: \.offset) { _, count in
                    Capsule()
                        .fill(count > 0 ? flapseAccent : Color(uiColor: .tertiarySystemFill))
                        .frame(maxWidth: .infinity)
                        .frame(height: count > 1 ? 38 : count > 0 ? 26 : 10)
                        .frame(maxHeight: 38, alignment: .bottom)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(entry.totalCaptures)")
                    .font(.title2.bold())
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(entry.streak)")
                    .font(.headline)
                    .monospacedDigit()
                Text("gün serisi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(captureURL)
        .containerBackground(for: .widget) { WidgetCanvas() }
    }
}

struct FlapseRhythmWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlapseRhythmWidgetV2", provider: FlapseProvider()) { entry in
            RhythmWidgetView(entry: entry)
        }
        .configurationDisplayName("Aktivite")
        .description("Gün serin ve bugünün çekim durumu.")
        .supportedFamilies([.systemSmall])
    }
}

struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FlapseWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(statusText, systemImage: entry.capturedToday ? "checkmark.circle.fill" : "camera.fill")
            case .accessoryCircular:
                Gauge(value: min(Double(entry.streak), 30), in: 0...30) {
                    Image(systemName: "flame.fill")
                } currentValueLabel: {
                    Text("\(entry.streak)")
                        .font(.headline)
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            default:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flapse")
                            .font(.caption.weight(.semibold))
                        Text("\(entry.streak) " ) + Text("gün serisi")
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: entry.capturedToday ? "checkmark.circle.fill" : "camera.circle.fill")
                        .font(.title2)
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(captureURL)
    }

    private var statusText: String {
        if entry.capturedToday { return String(localized: "Bugün çekildi") }
        if entry.dueCount > 0 { return String(localized: "Bugün \(entry.dueCount) çekim") }
        return String(localized: "Bugün için tamam")
    }
}

struct FlapseLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlapseLockScreenWidget", provider: FlapseProvider()) { entry in
            LockScreenWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Flapse")
        .description("Gün serin ve bugünün çekim durumu.")
        .supportedFamilies([.accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct FlapseWidgetBundle: WidgetBundle {
    var body: some Widget {
        FlapseFocusWidget()
        FlapseJourneyWidget()
        FlapseRhythmWidget()
        FlapseLockScreenWidget()
        FlapseRenderLiveActivity()
    }
}
