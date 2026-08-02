import AVFoundation
import BackgroundTasks
import Foundation
import SwiftData
import UIKit

enum TimelapseLibrary {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedTimelapses", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @MainActor
    static func save(videoURL: URL, title: String, context: ModelContext) async throws -> SavedTimelapse {
        let fileName = "\(UUID().uuidString).mp4"
        let destination = try await Task.detached(priority: .utility) {
            let destination = directory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: videoURL, to: destination)
            return destination
        }.value

        let asset = AVURLAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let posterData = await makePosterData(videoURL: destination, duration: duration)

        let item = SavedTimelapse(title: title, fileName: fileName, duration: duration, posterData: posterData)
        context.insert(item)
        do {
            try context.save()
        } catch {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: destination)
            }.value
            throw error
        }
        return item
    }

    static func makePosterData(videoURL: URL, duration: Double? = nil) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let resolvedDuration: Double
        if let duration {
            resolvedDuration = duration
        } else {
            resolvedDuration = (try? await asset.load(.duration).seconds) ?? 0
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let sampleSecond = resolvedDuration.isFinite ? min(max(resolvedDuration * 0.05, 0.05), 0.25) : 0.1
        let sampleTime = CMTime(seconds: sampleSecond, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: sampleTime).image {
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
        }
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }

    static let retentionDays = 7

    @MainActor
    static func softDelete(_ item: SavedTimelapse, context: ModelContext) {
        item.deletedAt = Date.now
        try? context.save()
    }

    @MainActor
    static func restore(_ item: SavedTimelapse, context: ModelContext) {
        item.deletedAt = nil
        try? context.save()
    }

    @MainActor
    static func setHidden(_ hidden: Bool, for item: SavedTimelapse, context: ModelContext) {
        item.isHidden = hidden
        try? context.save()
    }

    @MainActor
    static func delete(_ item: SavedTimelapse, context: ModelContext) {
        try? FileManager.default.removeItem(at: item.fileURL)
        context.delete(item)
        try? context.save()
    }

    @MainActor
    static func purgeExpired(context: ModelContext, now: Date = Date.now) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let descriptor = FetchDescriptor<SavedTimelapse>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        guard let deleted = try? context.fetch(descriptor) else { return }
        for item in deleted where (item.deletedAt ?? now) < cutoff {
            delete(item, context: context)
        }
        removeOrphanFiles(context: context)
    }

    @MainActor
    private static func removeOrphanFiles(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<SavedTimelapse>()) else { return }
        let referenced = Set(all.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

@MainActor
@Observable
final class TimelapseRenderService {

    static let shared = TimelapseRenderService()

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                TimelapseRenderService.shared.pruneStaleJobs()
                TimelapseRenderService.shared.resumeBackgroundFailures()
            }
        }
    }

    private func resumeBackgroundFailures() {
        for job in jobs where job.viewModel.retryAfterBackgroundFailure() {
            rearm(job)
        }
    }

    struct Job: Identifiable {
        let id: UUID
        let title: String
        let startedAt: Date
        let viewModel: TimelapseExportViewModel
        var isSaved = false
    }

    private(set) var jobs: [Job] = []
    private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var continuedTasks: [UUID: BGTask] = [:]
    private var registeredContinuedIdentifiers: Set<String> = []
    private var systemActivityJobs: Set<UUID> = []

    var activeJobs: [Job] {
        jobs.filter { $0.viewModel.phase == .rendering }
    }

    var finishedJobs: [Job] {
        jobs.filter {
            guard !$0.isSaved else { return false }
            if case .finished(let url) = $0.viewModel.phase {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return false
        }
    }

    private func pruneStaleJobs() {
        jobs.removeAll { job in
            guard case .finished(let url) = job.viewModel.phase else { return false }
            return job.isSaved || !FileManager.default.fileExists(atPath: url.path)
        }
    }

    func viewModel(for project: Project) -> TimelapseExportViewModel {
        if let job = jobs.first(where: { $0.id == project.id }) { return job.viewModel }
        let composer: any TimelapseComposing = project.category.isVideoMode ? VideoClipComposer() : TimelapseComposer()
        let job = Job(id: project.id, title: project.title, startedAt: Date.now, viewModel: TimelapseExportViewModel(composer: composer))
        jobs.append(job)
        return job.viewModel
    }

    func didStartRender(for project: Project) {
        guard let job = jobs.first(where: { $0.id == project.id }) else { return }
        rearm(job)
    }

    private func rearm(_ job: Job) {
        let id = job.id
        let usesSystemActivity = requestContinuedProcessing(for: job)
        if backgroundTasks[id] == nil {
            backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "timelapse-render") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask(for: id) }
            }
        }
        if !usesSystemActivity {
            RenderActivityCenter.start(id: id, title: job.title)
        }
        Task {
            while job.viewModel.phase == .rendering {
                if !usesSystemActivity {
                    RenderActivityCenter.update(id: id, progress: job.viewModel.progress)
                }
                if #available(iOS 26.0, *),
                   let task = continuedTasks[id] as? BGContinuedProcessingTask {
                    task.progress.completedUnitCount = Int64(job.viewModel.progress * 100)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task {
            await job.viewModel.waitForRender()
            endBackgroundTask(for: id)
            let usedSystemActivity = systemActivityJobs.contains(id)
            finishContinuedTask(for: id, success: {
                if case .finished = job.viewModel.phase { return true }
                return false
            }())
            if case .finished = job.viewModel.phase {
                if !usedSystemActivity {
                    RenderActivityCenter.finish(id: id, success: true)
                }
            } else if !job.viewModel.failedInBackground {
                if !usedSystemActivity {
                    RenderActivityCenter.finish(id: id, success: false)
                }
            }
        }
    }

    func cancel(projectID: UUID) {
        guard let job = jobs.first(where: { $0.id == projectID }) else { return }
        job.viewModel.cancel()
        if !systemActivityJobs.contains(projectID) {
            RenderActivityCenter.finish(id: projectID, success: false)
        }
        endBackgroundTask(for: projectID)
        finishContinuedTask(for: projectID, success: false)
    }

    func discard(projectID: UUID) {
        cancel(projectID: projectID)
        jobs.removeAll { $0.id == projectID }
    }

    func saveToLibrary(projectID: UUID, context: ModelContext) async -> SavedTimelapse? {
        guard let job = jobs.first(where: { $0.id == projectID }),
              case .finished(let url) = job.viewModel.phase else { return nil }
        let saved = try? await TimelapseLibrary.save(videoURL: url, title: job.title, context: context)
        if saved != nil {
            jobs.removeAll { $0.id == projectID }
        }
        return saved
    }

    private func endBackgroundTask(for id: UUID) {
        if let task = backgroundTasks.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func requestContinuedProcessing(for job: Job) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let identifier = continuedIdentifier(for: job.id)
        if !registeredContinuedIdentifiers.contains(identifier) {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: .main
            ) { [weak self] task in
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    self?.attach(continuedTask, to: job.id)
                }
            }
            guard registered else { return false }
            registeredContinuedIdentifiers.insert(identifier)
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: job.title,
            subtitle: String(localized: "Timelapse hazırlanıyor…", bundle: .appLanguage)
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            systemActivityJobs.insert(job.id)
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask, to id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.viewModel.phase == .rendering else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTasks[id] = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64(job.viewModel.progress * 100)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.jobs.first(where: { $0.id == id })?.viewModel.pauseForBackgroundExpiration()
                self?.finishContinuedTask(for: id, success: false)
            }
        }
        endBackgroundTask(for: id)
    }

    private func finishContinuedTask(for id: UUID, success: Bool) {
        if #available(iOS 26.0, *), let task = continuedTasks.removeValue(forKey: id) {
            task.setTaskCompleted(success: success)
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedIdentifier(for: id))
        systemActivityJobs.remove(id)
    }

    private func continuedIdentifier(for id: UUID) -> String {
        "rozcan.Flapse.timelapse.\(id.uuidString)"
    }
}
