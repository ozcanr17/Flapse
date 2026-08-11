import CloudKit
import Foundation
import ImageIO
import SwiftData
import UIKit

@MainActor
final class SharedProjectService {

    static let shared = SharedProjectService()
    static let containerIdentifier = "iCloud.rozcan.Flapse"

    /// UI testleri imzasız/in-memory bir uygulama süreciyle çalışabilir. Böyle bir
    /// süreçte CKContainer oluşturmak hata döndürmek yerine SIGTRAP üretebildiği
    /// için CloudKit'e hiç dokunmuyoruz. Normal simülatör ve cihaz davranışı değişmez.
    static var isEnabledForCurrentProcess: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--uitests")
            && ProcessInfo.processInfo.environment["FLAPSE_UI_TESTS"] != "1"
        #else
        true
        #endif
    }

    let container = CKContainer(identifier: SharedProjectService.containerIdentifier)
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }
    private var pendingPushes: [UUID: Task<Void, Never>] = [:]
    private var synchronizationTasks: [UUID: Task<Void, Never>] = [:]
    private var zoneRecordCaches: [String: ZoneRecordCache] = [:]
    private var zoneCacheOrder: [String] = []
    private let zoneCacheLimit = 24

    enum RecordType {
        static let project = "SharedProject"
        static let entry = "SharedEntry"
    }

    enum ShareError: Error {
        case notSignedIntoiCloud
        case shareNotReturned
    }

    struct SharedEntrySnapshot {
        let id: UUID
        let data: Data?
        let capturedAt: Date
        let imageRevision: Int
        let latitude: Double?
        let longitude: Double?
        let placeName: String?
        let deletedAt: Date?
        let updatedAt: Date
        let imageUpdatedAt: Date
        let isLegacy: Bool
    }

    struct SharedProjectSnapshot {
        let shareRecordName: String
        let rootRecordName: String
        let zoneName: String
        let ownerName: String
        let title: String
        let categoryRaw: String
        let cadenceRaw: String
        let createdAt: Date
        let deletedAt: Date?
        let updatedAt: Date
        let purgedEntryIDs: Set<UUID>
        let entries: [SharedEntrySnapshot]
    }

    private struct LocalEntrySnapshot: Sendable {
        let id: UUID
        let needsImageUpload: Bool
        let capturedAt: Date
        let imageRevision: Int
        let latitude: Double?
        let longitude: Double?
        let placeName: String?
        let deletedAt: Date?
        let updatedAt: Date
        let imageUpdatedAt: Date
    }

    private struct LocalProjectSnapshot {
        let rootRecordName: String
        let zoneID: CKRecordZone.ID
        let title: String
        let categoryRaw: String
        let cadenceRaw: String
        let createdAt: Date
        let deletedAt: Date?
        let updatedAt: Date
        let purgedEntryIDs: Set<UUID>
        let entries: [LocalEntrySnapshot]
    }

    private struct ZoneRecordCache {
        var records: [CKRecord.ID: CKRecord]
        var changeToken: CKServerChangeToken?
    }

    func accountAvailable() async -> Bool {
        ((try? await container.accountStatus()) ?? .couldNotDetermine) == .available
    }

    static func accountAvailableIfSupported() async -> Bool {
        guard isEnabledForCurrentProcess else { return false }
        return await shared.accountAvailable()
    }

    func createShare(project: Project) async throws -> CKShare {
        guard await accountAvailable() else { throw ShareError.notSignedIntoiCloud }
        let zoneID = projectZoneID(for: project.id)
        try await ensureZone(zoneID)

        let rootID = CKRecord.ID(recordName: project.id.uuidString, zoneID: zoneID)
        let updatedAt = Date()
        project.sharedUpdatedAt = updatedAt
        let root = projectRecord(
            id: rootID,
            title: project.title,
            categoryRaw: project.category.rawValue,
            cadenceRaw: project.cadence.rawValue,
            createdAt: project.createdAt,
            deletedAt: project.deletedAt,
            updatedAt: updatedAt,
            purgedEntryIDs: project.cloudPurgedEntryIDs
        )
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = project.title as CKRecordValue
        share.publicPermission = .readWrite

        let result = try await privateDB.modifyRecords(saving: [root, share], deleting: [])
        guard
            case .success(let saved)? = result.saveResults[share.recordID],
            let savedShare = saved as? CKShare
        else {
            throw ShareError.shareNotReturned
        }

        project.isCollaborative = true
        project.cloudShareRecordName = savedShare.recordID.recordName
        project.cloudRootRecordName = rootID.recordName
        project.cloudZoneName = zoneID.zoneName
        project.cloudOwnerName = zoneID.ownerName

        let snapshot = makeLocalSnapshot(project)
        try await upload(snapshot, to: privateDB, sourceProject: project)
        try? await installSubscription(zoneID: zoneID, database: privateDB)
        return savedShare
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }

    func fetchSharedProject(_ metadata: CKShare.Metadata) async throws -> SharedProjectSnapshot? {
        let zoneID = metadata.share.recordID.zoneID
        let records = try await records(in: zoneID, database: sharedDB)
        guard let root = projectRoot(in: records, shareRecordName: metadata.share.recordID.recordName) else {
            return nil
        }
        try? await installSubscription(zoneID: zoneID, database: sharedDB)
        return await makeSnapshot(
            records: records,
            root: root,
            shareRecordName: metadata.share.recordID.recordName,
            zoneID: zoneID
        )
    }

    func synchronize(_ project: Project, context: ModelContext) async {
        if let task = synchronizationTasks[project.id] {
            await task.value
            return
        }
        let projectID = project.id
        let task = Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            await self.performSynchronization(project, context: context)
        }
        synchronizationTasks[projectID] = task
        await task.value
        synchronizationTasks[projectID] = nil
    }

    private func performSynchronization(_ project: Project, context: ModelContext) async {
        do {
            guard let reference = try await resolveReference(for: project) else { return }
            let database = database(for: reference.zoneID)
            let records = try await records(in: reference.zoneID, database: database)
            let root = project.cloudShareRecordName
                .flatMap { projectRoot(in: records, shareRecordName: $0) }
                ?? records.first(where: { $0.recordID.recordName == reference.rootRecordName })
            guard let root else { return }
            project.cloudRootRecordName = root.recordID.recordName
            project.cloudZoneName = root.recordID.zoneID.zoneName
            project.cloudOwnerName = root.recordID.zoneID.ownerName
            let localImageVersions = localImageVersions(for: project)
            let remote = await makeSnapshot(
                records: records,
                root: root,
                shareRecordName: project.cloudShareRecordName ?? "",
                zoneID: reference.zoneID,
                localImageVersions: localImageVersions
            )
            repairMisassignedEntries(in: project, rootID: root.recordID, records: records, context: context)
            merge(remote, into: project, context: context)
            try context.save()
            try await upload(
                makeLocalSnapshot(project, comparedTo: records),
                to: database,
                comparedTo: records,
                sourceProject: project
            )
            try? await installSubscription(zoneID: reference.zoneID, database: database)
        } catch {
            return
        }
    }

    func schedulePush(for project: Project) {
        guard project.isCollaborative else { return }
        pendingPushes[project.id]?.cancel()
        pendingPushes[project.id] = Task { @MainActor [weak self, weak project] in
            try? await Task.sleep(for: .milliseconds(700))
            guard
                !Task.isCancelled,
                let self,
                let project,
                let reference = try? await self.resolveReference(for: project)
            else { return }
            let database = self.database(for: reference.zoneID)
            let records = try? await self.records(in: reference.zoneID, database: database)
            let snapshot = self.makeLocalSnapshot(project, comparedTo: records)
            try? await self.upload(snapshot, to: database, comparedTo: records, sourceProject: project)
            self.pendingPushes[project.id] = nil
        }
    }

    private func reference(for project: Project) -> (rootRecordName: String, zoneID: CKRecordZone.ID)? {
        guard
            project.isCollaborative,
            let rootRecordName = project.cloudRootRecordName,
            let zoneName = project.cloudZoneName,
            let ownerName = project.cloudOwnerName
        else { return nil }
        return (rootRecordName, CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName))
    }

    private func resolveReference(for project: Project) async throws -> (rootRecordName: String, zoneID: CKRecordZone.ID)? {
        if let reference = reference(for: project) { return reference }
        guard project.isCollaborative, let shareName = project.cloudShareRecordName else { return nil }

        for zone in try await privateDB.allRecordZones() {
            if let ownerRecords = try? await records(in: zone.zoneID, database: privateDB),
               let root = ownerRecords.first(where: {
                   $0.recordType == RecordType.project && $0.share?.recordID.recordName == shareName
               }) {
                project.cloudRootRecordName = root.recordID.recordName
                project.cloudZoneName = root.recordID.zoneID.zoneName
                project.cloudOwnerName = root.recordID.zoneID.ownerName
                return (root.recordID.recordName, root.recordID.zoneID)
            }
        }

        for zone in try await sharedDB.allRecordZones() {
            if let sharedRecords = try? await records(in: zone.zoneID, database: sharedDB),
               let root = sharedRecords.first(where: {
                   $0.recordType == RecordType.project && $0.share?.recordID.recordName == shareName
               }) {
                project.cloudRootRecordName = root.recordID.recordName
                project.cloudZoneName = root.recordID.zoneID.zoneName
                project.cloudOwnerName = root.recordID.zoneID.ownerName
                return (root.recordID.recordName, root.recordID.zoneID)
            }
        }
        return nil
    }

    private func database(for zoneID: CKRecordZone.ID) -> CKDatabase {
        zoneID.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB
    }

    private func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    private func projectRecord(
        id: CKRecord.ID,
        existing: CKRecord? = nil,
        title: String,
        categoryRaw: String,
        cadenceRaw: String,
        createdAt: Date,
        deletedAt: Date?,
        updatedAt: Date,
        purgedEntryIDs: Set<UUID>
    ) -> CKRecord {
        let record = existing ?? CKRecord(recordType: RecordType.project, recordID: id)
        record["title"] = title as CKRecordValue
        record["category"] = categoryRaw as CKRecordValue
        record["cadence"] = cadenceRaw as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["deletedAt"] = deletedAt as CKRecordValue?
        record["purgedEntryIDs"] = purgedEntryIDs.map(\.uuidString).sorted().joined(separator: "\n") as CKRecordValue
        return record
    }

    private func entryRecord(
        _ entry: LocalEntrySnapshot,
        imageData: Data?,
        existing: CKRecord?,
        parentID: CKRecord.ID
    ) -> (CKRecord, URL?) {
        let recordID = CKRecord.ID(recordName: entry.id.uuidString, zoneID: parentID.zoneID)
        let record = existing ?? CKRecord(recordType: RecordType.entry, recordID: recordID)
        record["capturedAt"] = entry.capturedAt as CKRecordValue
        record["latitude"] = entry.latitude as CKRecordValue?
        record["longitude"] = entry.longitude as CKRecordValue?
        record["placeName"] = entry.placeName as CKRecordValue?
        record["deletedAt"] = entry.deletedAt as CKRecordValue?
        record["updatedAt"] = entry.updatedAt as CKRecordValue
        record["project"] = CKRecord.Reference(recordID: parentID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: parentID, action: .none)
        let remoteImageUpdatedAt = existing?["imageUpdatedAt"] as? Date ?? .distantPast
        guard existing == nil || entry.imageUpdatedAt > remoteImageUpdatedAt else { return (record, nil) }
        record["imageRevision"] = entry.imageRevision as CKRecordValue
        record["imageUpdatedAt"] = entry.imageUpdatedAt as CKRecordValue
        guard let imageData else { return (record, nil) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-shared-\(entry.id.uuidString)-\(UUID().uuidString).jpg")
        do {
            try imageData.write(to: url, options: .atomic)
            record["image"] = CKAsset(fileURL: url)
            return (record, url)
        } catch {
            return (record, nil)
        }
    }

    private func upload(
        _ snapshot: LocalProjectSnapshot,
        to database: CKDatabase,
        comparedTo remoteRecords: [CKRecord]? = nil,
        sourceProject: Project
    ) async throws {
        let rootID = CKRecord.ID(recordName: snapshot.rootRecordName, zoneID: snapshot.zoneID)
        let remoteByID = recordsByID(remoteRecords ?? [])
        let safePurgedEntryIDs = Set(snapshot.purgedEntryIDs.filter { id in
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: snapshot.zoneID)
            guard let remote = remoteByID[recordID] else { return true }
            return entryRootID(for: remote) == rootID
        })
        let remoteRootDate = remoteByID[rootID]?["updatedAt"] as? Date ?? .distantPast
        if remoteRecords == nil || snapshot.updatedAt > remoteRootDate {
            let root = projectRecord(
                id: rootID,
                existing: remoteByID[rootID],
                title: snapshot.title,
                categoryRaw: snapshot.categoryRaw,
                cadenceRaw: snapshot.cadenceRaw,
                createdAt: snapshot.createdAt,
                deletedAt: snapshot.deletedAt,
                updatedAt: snapshot.updatedAt,
                purgedEntryIDs: safePurgedEntryIDs
            )
            _ = try await database.modifyRecords(saving: [root], deleting: [], savePolicy: .changedKeys, atomically: false)
        }

        let purgedRecordIDs = safePurgedEntryIDs
            .map { CKRecord.ID(recordName: $0.uuidString, zoneID: snapshot.zoneID) }
            .filter { id in
                guard let remote = remoteByID[id] else { return false }
                return entryRootID(for: remote) == rootID
            }
        if !purgedRecordIDs.isEmpty {
            _ = try await database.modifyRecords(saving: [], deleting: purgedRecordIDs)
        }

        let changedEntries = snapshot.entries.filter { entry in
            guard remoteRecords != nil else { return true }
            let id = CKRecord.ID(recordName: entry.id.uuidString, zoneID: snapshot.zoneID)
            guard let remote = remoteByID[id] else { return true }
            guard entryRootID(for: remote) == rootID else { return false }
            let remoteDate = remote["updatedAt"] as? Date ?? remote.modificationDate ?? .distantPast
            return entry.updatedAt > remoteDate
        }
        var sourceEntriesByID: [UUID: Entry] = [:]
        for entry in sourceProject.entries ?? [] where !entry.isDeleted {
            // Bozuk/eski veride yinelenen UUID varsa Dictionary(uniqueKeysWithValues:)
            // trap üretmesin; en güncel nesne yeterlidir.
            let current = sourceEntriesByID[entry.id]
            if current == nil || entry.imageRevision >= (current?.imageRevision ?? -1) {
                sourceEntriesByID[entry.id] = entry
            }
        }

        // Bir iPhone fotoğrafının decode sırasında yüzlerce MB geçici bellek
        // kullanabildiğini unutma. Küçük partiler CloudKit limitinin altında kalır
        // ve büyük projelerde tepe belleği sınırlı tutar.
        for batch in changedEntries.chunked(into: 8) {
            let pending = batch.map { entry in
                (entry, entry.needsImageUpload ? sourceEntriesByID[entry.id]?.imageData : nil)
            }
            let prepared = await Task.detached(priority: .utility) {
                pending.map { ($0.0, Self.sharedImageData($0.1)) }
            }.value
            let pairs = prepared.map { entry, data in
                let id = CKRecord.ID(recordName: entry.id.uuidString, zoneID: snapshot.zoneID)
                return entryRecord(
                    entry,
                    imageData: data,
                    existing: remoteByID[id],
                    parentID: rootID
                )
            }
            defer { pairs.compactMap(\.1).forEach { try? FileManager.default.removeItem(at: $0) } }
            _ = try await database.modifyRecords(
                saving: pairs.map(\.0),
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
        }
    }

    private func records(
        in zoneID: CKRecordZone.ID,
        database: CKDatabase,
        canRecoverExpiredToken: Bool = true
    ) async throws -> [CKRecord] {
        let cacheKey = "\(database.databaseScope.rawValue)-\(zoneID.ownerName)-\(zoneID.zoneName)"
        var cache = zoneRecordCaches[cacheKey] ?? ZoneRecordCache(records: [:], changeToken: nil)
        do {
            repeat {
                let changes = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: cache.changeToken
                )
                for record in changes.modificationResultsByID.compactMap({ try? $0.value.get().record }) {
                    if let existing = cache.records[record.recordID],
                       (existing.modificationDate ?? .distantPast) > (record.modificationDate ?? .distantPast) {
                        continue
                    }
                    cache.records[record.recordID] = record
                }
                for deletion in changes.deletions {
                    cache.records[deletion.recordID] = nil
                }
                cache.changeToken = changes.changeToken
                store(cache, for: cacheKey)
                if !changes.moreComing { break }
            } while true
            return Array(cache.records.values)
        } catch let error as CKError where error.code == .changeTokenExpired && canRecoverExpiredToken {
            zoneRecordCaches[cacheKey] = nil
            zoneCacheOrder.removeAll { $0 == cacheKey }
            return try await records(in: zoneID, database: database, canRecoverExpiredToken: false)
        }
    }

    private func store(_ cache: ZoneRecordCache, for key: String) {
        zoneRecordCaches[key] = cache
        zoneCacheOrder.removeAll { $0 == key }
        zoneCacheOrder.append(key)
        while zoneCacheOrder.count > zoneCacheLimit {
            zoneRecordCaches[zoneCacheOrder.removeFirst()] = nil
        }
    }

    private func makeSnapshot(
        records: [CKRecord],
        root: CKRecord,
        shareRecordName: String,
        zoneID: CKRecordZone.ID,
        localImageVersions: [UUID: Date]? = nil
    ) async -> SharedProjectSnapshot {
        let entryRecords = records
            .filter {
                $0.recordType == RecordType.entry && entryRootID(for: $0) == root.recordID
            }
        let entries = await Task.detached(priority: .utility) {
            entryRecords
                .compactMap { record in
                    let id = UUID(uuidString: record.recordID.recordName)
                    let remoteImageDate = record["imageUpdatedAt"] as? Date ?? record.modificationDate ?? .distantPast
                    let includeImage = id.flatMap { localImageVersions?[$0] }.map { remoteImageDate > $0 } ?? true
                    return Self.sharedEntrySnapshot(record, includeImage: includeImage)
                }
                .sorted { $0.capturedAt < $1.capturedAt }
        }.value
        return SharedProjectSnapshot(
            shareRecordName: shareRecordName,
            rootRecordName: root.recordID.recordName,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            title: root["title"] as? String ?? String(localized: "Ortak Proje", bundle: .appLanguage),
            categoryRaw: root["category"] as? String ?? ProjectCategory.other.rawValue,
            cadenceRaw: root["cadence"] as? String ?? CaptureCadence.daily.rawValue,
            createdAt: root["createdAt"] as? Date ?? .now,
            deletedAt: root["deletedAt"] as? Date,
            updatedAt: root["updatedAt"] as? Date ?? root.modificationDate ?? .distantPast,
            purgedEntryIDs: Set((root["purgedEntryIDs"] as? String ?? "")
                .split(separator: "\n")
                .compactMap { UUID(uuidString: String($0)) }),
            entries: entries
        )
    }

    private func makeLocalSnapshot(_ project: Project, comparedTo remoteRecords: [CKRecord]? = nil) -> LocalProjectSnapshot {
        let zoneID = CKRecordZone.ID(
            zoneName: project.cloudZoneName ?? projectZoneID(for: project.id).zoneName,
            ownerName: project.cloudOwnerName ?? CKCurrentUserDefaultName
        )
        let remoteByID = recordsByID(remoteRecords ?? [])
        return LocalProjectSnapshot(
            rootRecordName: project.cloudRootRecordName ?? project.id.uuidString,
            zoneID: zoneID,
            title: project.title,
            categoryRaw: project.category.rawValue,
            cadenceRaw: project.cadence.rawValue,
            createdAt: project.createdAt,
            deletedAt: project.deletedAt,
            updatedAt: project.sharedUpdatedAt ?? project.createdAt,
            purgedEntryIDs: project.cloudPurgedEntryIDs,
            entries: (project.entries ?? []).filter { !$0.isDeleted }.map {
                let recordID = CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
                let remoteImageDate = remoteByID[recordID]?["imageUpdatedAt"] as? Date ?? .distantPast
                let imageUpdatedAt = $0.sharedImageUpdatedAt ?? $0.capturedAt
                return LocalEntrySnapshot(
                    id: $0.id,
                    needsImageUpload: remoteRecords == nil
                        || remoteByID[recordID] == nil
                        || imageUpdatedAt > remoteImageDate,
                    capturedAt: $0.capturedAt,
                    imageRevision: $0.imageRevision,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    placeName: $0.placeName,
                    deletedAt: $0.deletedAt,
                    updatedAt: $0.sharedUpdatedAt ?? $0.capturedAt,
                    imageUpdatedAt: imageUpdatedAt
                )
            }
        )
    }

    private func localImageVersions(for project: Project) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for entry in project.entries ?? [] where !entry.isDeleted {
            result[entry.id] = entry.sharedImageUpdatedAt ?? entry.capturedAt
        }
        return result
    }

    private func merge(_ snapshot: SharedProjectSnapshot, into project: Project, context: ModelContext) {
        let purgedEntryIDs = snapshot.purgedEntryIDs.union(project.cloudPurgedEntryIDs)
        project.cloudPurgedEntryIDs = purgedEntryIDs
        for entry in project.entries ?? [] where purgedEntryIDs.contains(entry.id) {
            context.delete(entry)
        }
        if snapshot.updatedAt >= (project.sharedUpdatedAt ?? .distantPast) {
            project.title = snapshot.title
            project.category = ProjectCategory(rawValue: snapshot.categoryRaw) ?? .other
            project.cadence = CaptureCadence(rawValue: snapshot.cadenceRaw) ?? .daily
            project.deletedAt = snapshot.deletedAt
            project.sharedUpdatedAt = snapshot.updatedAt
        }
        var localByID: [UUID: Entry] = [:]
        for entry in project.entries ?? [] where !entry.isDeleted {
            if let existing = localByID[entry.id] {
                let existingDate = existing.sharedUpdatedAt ?? existing.capturedAt
                let candidateDate = entry.sharedUpdatedAt ?? entry.capturedAt
                if candidateDate > existingDate { localByID[entry.id] = entry }
            } else {
                localByID[entry.id] = entry
            }
        }
        var claimedLegacyEntries: Set<ObjectIdentifier> = []
        for remote in snapshot.entries {
            guard !purgedEntryIDs.contains(remote.id) else { continue }
            if let local = localByID[remote.id] {
                if let data = remote.data,
                   remote.imageUpdatedAt >= (local.sharedImageUpdatedAt ?? .distantPast) {
                    local.imageData = data
                    local.imageRevision = remote.imageRevision
                    local.sharedImageUpdatedAt = remote.imageUpdatedAt
                }
                if remote.updatedAt >= (local.sharedUpdatedAt ?? .distantPast) {
                    local.capturedAt = remote.capturedAt
                    local.latitude = remote.latitude
                    local.longitude = remote.longitude
                    local.placeName = remote.placeName
                    local.deletedAt = remote.deletedAt
                    local.sharedUpdatedAt = remote.updatedAt
                }
            } else {
                if remote.isLegacy,
                   let local = (project.entries ?? []).first(where: {
                       !claimedLegacyEntries.contains(ObjectIdentifier($0))
                           && abs($0.capturedAt.timeIntervalSince(remote.capturedAt)) < 1
                   }) {
                    claimedLegacyEntries.insert(ObjectIdentifier(local))
                    local.id = remote.id
                    local.sharedUpdatedAt = remote.updatedAt
                    local.sharedImageUpdatedAt = remote.imageUpdatedAt
                    continue
                }
                if let deletedAt = remote.deletedAt,
                   deletedAt < Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast {
                    continue
                }
                let entry = Entry(id: remote.id, capturedAt: remote.capturedAt, imageData: remote.data)
                entry.imageRevision = remote.imageRevision
                entry.latitude = remote.latitude
                entry.longitude = remote.longitude
                entry.placeName = remote.placeName
                entry.deletedAt = remote.deletedAt
                entry.sharedUpdatedAt = remote.updatedAt
                entry.sharedImageUpdatedAt = remote.imageUpdatedAt
                entry.project = project
                context.insert(entry)
            }
        }
    }

    func projectRoot(in records: [CKRecord], shareRecordName: String) -> CKRecord? {
        records.first {
            $0.recordType == RecordType.project && $0.share?.recordID.recordName == shareRecordName
        }
    }

    func projectZoneID(for projectID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "SharedProject-\(projectID.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    func entryRootID(for record: CKRecord) -> CKRecord.ID? {
        (record["project"] as? CKRecord.Reference)?.recordID ?? record.parent?.recordID
    }

    func repairMisassignedEntries(
        in project: Project,
        rootID: CKRecord.ID,
        records: [CKRecord],
        context: ModelContext
    ) {
        var owners: [UUID: CKRecord.ID] = [:]
        for record in records where record.recordType == RecordType.entry {
            guard
                let id = UUID(uuidString: record.recordID.recordName),
                let owner = entryRootID(for: record)
            else { continue }
            owners[id] = owner
        }

        let foreignIDs = Set(owners.compactMap { $0.value == rootID ? nil : $0.key })
        if !foreignIDs.isEmpty {
            project.cloudPurgedEntryIDs.subtract(foreignIDs)
        }
        for entry in project.entries ?? [] where foreignIDs.contains(entry.id) {
            context.delete(entry)
        }
    }

    private func recordsByID(_ records: [CKRecord]) -> [CKRecord.ID: CKRecord] {
        var result: [CKRecord.ID: CKRecord] = [:]
        for record in records {
            if let existing = result[record.recordID],
               (existing.modificationDate ?? .distantPast) > (record.modificationDate ?? .distantPast) {
                continue
            }
            result[record.recordID] = record
        }
        return result
    }

    private nonisolated static func sharedImageData(_ data: Data?) -> Data? {
        guard let data else { return nil }
        let maxDimension: CGFloat = 2400
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return data }
        guard max(width, height) > maxDimension else { return data }

        // UIImage(data:) önce tam çözünürlüklü bitmap oluşturuyordu. ImageIO doğrudan
        // hedef boyutta decode ederek 48 MP karelerdeki büyük bellek sıçramasını önler.
        guard let image = ImageDownsampler.image(from: data, maxPixelSize: maxDimension) else { return data }
        return image.jpegData(compressionQuality: 0.9) ?? data
    }

    private nonisolated static func sharedEntrySnapshot(
        _ record: CKRecord,
        includeImage: Bool = true
    ) -> SharedEntrySnapshot? {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        let asset = record["image"] as? CKAsset
        let data = includeImage ? asset?.fileURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) } : nil
        return SharedEntrySnapshot(
            id: id,
            data: data,
            capturedAt: record["capturedAt"] as? Date ?? .now,
            imageRevision: record["imageRevision"] as? Int ?? 0,
            latitude: record["latitude"] as? Double,
            longitude: record["longitude"] as? Double,
            placeName: record["placeName"] as? String,
            deletedAt: record["deletedAt"] as? Date,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast,
            imageUpdatedAt: record["imageUpdatedAt"] as? Date ?? record.modificationDate ?? .distantPast,
            isLegacy: record["updatedAt"] == nil
        )
    }

    private func installSubscription(zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        let key = "\(zoneID.zoneName)-\(zoneID.ownerName)"
            .data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_") ?? UUID().uuidString
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "flapse-shared-\(key)")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    static func participantNames(of share: CKShare) -> [String] {
        share.participants.compactMap { participant in
            let components = participant.userIdentity.nameComponents
            let name = [components?.givenName, components?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
