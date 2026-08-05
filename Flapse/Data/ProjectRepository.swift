import Foundation
import SwiftData

/// Veri katmanına erişimin tek kapısı. Arayüz ve ViewModel'lar SwiftData'yı doğrudan
/// değil, bu protokol üzerinden kullanır. Böylece testte gerçek implementasyon yerine
/// bellek içi (veya sahte/mock) bir implementasyon enjekte edebiliriz — bağımlılık
/// enjeksiyonunun (DI) özü budur.
///
/// `@MainActor`: SwiftData'nın ana context'i (mainContext) ana iş parçacığına (main
/// thread) bağlıdır. Bu yüzden repository'yi de ana aktöre sabitliyoruz.
@MainActor
protocol ProjectRepositoryProtocol {
    func createProject(title: String, category: ProjectCategory, cadence: CaptureCadence) throws -> Project
    func allProjects() throws -> [Project]
    func addEntry(_ entry: Entry, to project: Project) throws
    func addEntries(_ entries: [Entry], to project: Project) throws
    func replaceImage(for entry: Entry, with data: Data) throws
    func deleteEntry(_ entry: Entry) throws
    func deleteProject(_ project: Project) throws
    func saveIfNeeded() throws
}

/// SwiftData (ve dolaylı olarak CloudKit) ile çalışan gerçek implementasyon.
@MainActor
final class ProjectRepository: ProjectRepositoryProtocol {

    private let context: ModelContext
    private static let maintenanceVersionKey = "persistenceMaintenanceVersion"
    private static let maintenanceVersion = 2

    /// Context'i dışarıdan alıyoruz: üretimde `container.mainContext`, testte ise
    /// bellek içi bir container'ın context'i. Aynı sınıf, iki farklı ortamda çalışır.
    init(context: ModelContext) {
        self.context = context
    }

    func createProject(title: String, category: ProjectCategory, cadence: CaptureCadence) throws -> Project {
        let project = Project(title: title, category: category, cadence: cadence)
        context.insert(project)
        try context.save()
        return project
    }

    func allProjects() throws -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).sorted {
            if $0.lastActivityDate == $1.lastActivityDate {
                return $0.createdAt > $1.createdAt
            }
            return $0.lastActivityDate > $1.lastActivityDate
        }
    }

    func addEntry(_ entry: Entry, to project: Project) throws {
        entry.sharedUpdatedAt = Date()
        entry.sharedImageUpdatedAt = entry.sharedImageUpdatedAt ?? entry.capturedAt
        entry.project = project       // ilişkiyi kur; inverse (project.entries) otomatik güncellenir
        context.insert(entry)
        try context.save()
        scheduleSharedSync(for: project)
    }

    func addEntries(_ entries: [Entry], to project: Project) throws {
        for entry in entries {
            entry.sharedUpdatedAt = entry.sharedUpdatedAt ?? Date()
            entry.sharedImageUpdatedAt = entry.sharedImageUpdatedAt ?? entry.capturedAt
            entry.project = project
            context.insert(entry)
        }
        try context.save()
        scheduleSharedSync(for: project)
    }

    func replaceImage(for entry: Entry, with data: Data) throws {
        entry.imageData = data
        entry.imageRevision += 1
        let updatedAt = Date()
        entry.sharedUpdatedAt = updatedAt
        entry.sharedImageUpdatedAt = updatedAt
        try context.save()
        if let project = entry.project { scheduleSharedSync(for: project) }
    }

    func updateCapturedAt(for entry: Entry, to date: Date) throws {
        entry.capturedAt = date
        entry.sharedUpdatedAt = Date()
        try context.save()
        if let project = entry.project { scheduleSharedSync(for: project) }
    }

    func updateCapturedAt(for entries: [Entry], to date: Date, preservingTime: Bool) throws {
        try updateCapturedAt(for: entries, to: date, preservingTime: preservingTime, calendar: .current)
    }

    func updateCapturedAt(
        for entries: [Entry],
        to date: Date,
        preservingTime: Bool,
        calendar: Calendar = .current
    ) throws {
        let selectedDay = calendar.dateComponents([.year, .month, .day], from: date)
        for entry in entries {
            if preservingTime {
                let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: entry.capturedAt)
                var components = selectedDay
                components.hour = time.hour
                components.minute = time.minute
                components.second = time.second
                components.nanosecond = time.nanosecond
                entry.capturedAt = calendar.date(from: components) ?? date
            } else {
                entry.capturedAt = date
            }
            entry.sharedUpdatedAt = Date()
        }
        try context.save()
        for project in Set(entries.compactMap(\.project)) { scheduleSharedSync(for: project) }
    }

    func updateLocation(
        for entries: [Entry],
        latitude: Double?,
        longitude: Double?,
        placeName: String?
    ) throws {
        for entry in entries {
            entry.latitude = latitude
            entry.longitude = longitude
            entry.placeName = placeName
            entry.sharedUpdatedAt = Date()
        }
        try context.save()
        for project in Set(entries.compactMap(\.project)) { scheduleSharedSync(for: project) }
    }

    func deleteEntry(_ entry: Entry) throws {
        entry.deletedAt = Date()
        entry.sharedUpdatedAt = Date()
        try context.save()
        if let project = entry.project { scheduleSharedSync(for: project) }
    }

    func restoreEntry(_ entry: Entry) throws {
        entry.deletedAt = nil
        entry.sharedUpdatedAt = Date()
        try context.save()
        if let project = entry.project { scheduleSharedSync(for: project) }
    }

    func permanentlyDeleteEntry(_ entry: Entry) throws {
        let videoURL = entry.videoFileURL
        if let project = entry.project, project.isCollaborative {
            markPurged(entry.id, in: project)
        }
        context.delete(entry)
        try saveIfNeeded()
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
    }

    func permanentlyDeleteEntries(_ entries: [Entry]) throws {
        let videoURLs = entries.compactMap(\.videoFileURL)
        for entry in entries {
            if let project = entry.project, project.isCollaborative {
                markPurged(entry.id, in: project)
            }
            context.delete(entry)
        }
        try saveIfNeeded()
        for videoURL in videoURLs { try? FileManager.default.removeItem(at: videoURL) }
    }

    func deleteProject(_ project: Project) throws {
        let videoURLs = (project.entries ?? []).compactMap(\.videoFileURL)
        context.delete(project)
        try saveIfNeeded()
        for videoURL in videoURLs { try? FileManager.default.removeItem(at: videoURL) }
    }

    /// Projeyi çöp kutusuna taşır: veri silinmez, yalnızca silinme anı işaretlenir.
    func softDeleteProject(_ project: Project) throws {
        project.deletedAt = Date()
        project.sharedUpdatedAt = Date()
        try context.save()
        scheduleSharedSync(for: project)
    }

    func restoreProject(_ project: Project) throws {
        project.deletedAt = nil
        project.sharedUpdatedAt = Date()
        try context.save()
        scheduleSharedSync(for: project)
    }

    func setHidden(_ hidden: Bool, for project: Project) throws {
        project.isHidden = hidden
        try context.save()
        let projects = try context.fetch(FetchDescriptor<Project>())
        ReminderScheduler.shared.sync(projects: projects)
        WidgetStateWriter.update(projects: projects)
    }

    /// Saklama süresi dolan (varsayılan 30 gün) projeleri kalıcı olarak siler.
    func purgeExpiredProjects(retentionDays: Int = 30, now: Date = Date()) throws {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        for project in try context.fetch(descriptor) where project.deletedAt.map({ $0 < cutoff }) == true {
            try deleteProject(project)
        }
        try saveIfNeeded()
    }

    func purgeExpiredEntries(retentionDays: Int = 30, now: Date = Date()) throws {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        for entry in try context.fetch(descriptor) where entry.deletedAt.map({ $0 < cutoff }) == true {
            if let project = entry.project, project.isCollaborative {
                markPurged(entry.id, in: project)
            }
            context.delete(entry)
        }
        try saveIfNeeded()
    }

    func repairDuplicateEntryIDs() throws {
        let entries = try context.fetch(FetchDescriptor<Entry>())
        var winners: [String: Entry] = [:]
        for entry in entries {
            let key = "\(entry.project?.id.uuidString ?? "orphan")-\(entry.id.uuidString)"
            guard let existing = winners[key] else {
                winners[key] = entry
                continue
            }
            let winner = preferredEntry(existing, entry)
            let duplicate = winner === existing ? entry : existing
            winners[key] = winner
            context.delete(duplicate)
        }
        try saveIfNeeded()
    }

    func runStartupMaintenanceIfNeeded() throws {
        guard UserDefaults.standard.integer(forKey: Self.maintenanceVersionKey) < Self.maintenanceVersion else {
            return
        }
        try repairDuplicateEntryIDs()
        UserDefaults.standard.set(Self.maintenanceVersion, forKey: Self.maintenanceVersionKey)
    }

    /// Bekleyen değişiklik varsa diske/Cloud'a yazar. Gereksiz kayıttan kaçınmak için
    /// önce değişiklik var mı diye bakıyoruz.
    func saveIfNeeded() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    func updateProject(_ project: Project, title: String, category: ProjectCategory, cadence: CaptureCadence) throws {
        project.title = title
        project.category = category
        project.cadence = cadence
        project.sharedUpdatedAt = Date()
        try context.save()
        scheduleSharedSync(for: project)
    }

    private func scheduleSharedSync(for project: Project) {
        guard project.isCollaborative, SharedProjectService.isEnabledForCurrentProcess else { return }
        SharedProjectService.shared.schedulePush(for: project)
    }

    private func markPurged(_ id: UUID, in project: Project) {
        var ids = project.cloudPurgedEntryIDs
        ids.insert(id)
        project.cloudPurgedEntryIDs = ids
        project.sharedUpdatedAt = Date()
        scheduleSharedSync(for: project)
    }

    private func preferredEntry(_ first: Entry, _ second: Entry) -> Entry {
        let firstDate = first.sharedUpdatedAt ?? first.capturedAt
        let secondDate = second.sharedUpdatedAt ?? second.capturedAt
        if firstDate != secondDate { return firstDate > secondDate ? first : second }
        if first.imageRevision != second.imageRevision {
            return first.imageRevision > second.imageRevision ? first : second
        }
        if (first.imageData != nil) != (second.imageData != nil) {
            return first.imageData != nil ? first : second
        }
        return first
    }
}
