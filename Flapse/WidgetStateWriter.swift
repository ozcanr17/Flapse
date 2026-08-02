import Foundation
import SwiftData
import UIKit
import WidgetKit

enum WidgetStateWriter {
    static let suiteName = "group.rozcan.Flapse"

    @MainActor
    static func update(projects: [Project]) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let liveProjects = projects.filter { !$0.isDeleted && $0.deletedAt == nil && !$0.isHidden }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var capturedDates: [Date] = []
        var projectCovers: [(project: Project, entry: Entry?)] = []
        var recentDayCounts = Array(repeating: 0, count: 7)
        var dueCount = 0

        for project in liveProjects {
            var last: Entry?
            for entry in project.entries ?? [] where !entry.isDeleted && entry.deletedAt == nil {
                capturedDates.append(entry.capturedAt)
                if last == nil || entry.capturedAt > (last?.capturedAt ?? .distantPast) {
                    last = entry
                }
                let day = calendar.startOfDay(for: entry.capturedAt)
                if let offset = calendar.dateComponents([.day], from: day, to: today).day,
                   recentDayCounts.indices.contains(offset) {
                    recentDayCounts[offset] += 1
                }
            }
            if project.cadence.isCaptureDue(lastCapture: last?.capturedAt) {
                dueCount += 1
            }
            projectCovers.append((project, last))
        }
        defaults.set(ActivitySummary.streak(capturedDates: capturedDates), forKey: "widget.streak")
        defaults.set(recentDayCounts.first.map { $0 > 0 } ?? false, forKey: "widget.capturedToday")
        defaults.set(dueCount, forKey: "widget.dueCount")
        defaults.set(capturedDates.count, forKey: "widget.totalCaptures")
        defaults.set(liveProjects.count, forKey: "widget.activeProjectCount")
        defaults.set(recentDayCounts, forKey: "widget.recentDayCounts")

        let covers = projectCovers
            .sorted { ($0.entry?.capturedAt ?? $0.project.createdAt) > ($1.entry?.capturedAt ?? $1.project.createdAt) }
            .prefix(4)
            .map { WidgetCover(title: $0.project.title, data: $0.entry?.imageData) }

        Task {
            await WidgetThumbnailWriter.shared.write(covers: covers)
        }
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent("widget", isDirectory: true)
    }
}

private struct WidgetCover: Sendable {
    let title: String
    let data: Data?
}

private actor WidgetThumbnailWriter {
    static let shared = WidgetThumbnailWriter()

    func write(covers: [WidgetCover]) async {
        guard let defaults = UserDefaults(suiteName: WidgetStateWriter.suiteName) else { return }
        guard let directory = WidgetStateWriter.containerURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in oldFiles where name.hasPrefix("grid-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }

        var titles: [String] = []
        for (index, cover) in covers.enumerated() {
            titles.append(cover.title)
            let url = directory.appendingPathComponent("project-\(index).jpg")
            if let image = await ImageDownsampler.image(from: cover.data, maxPixelSize: 480),
               let jpeg = ImageDownsampler.opaqueJPEGData(from: image, compressionQuality: 0.76) {
                try? jpeg.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for index in covers.count..<4 {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("project-\(index).jpg"))
        }
        defaults.set(titles, forKey: "widget.projectTitles")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
