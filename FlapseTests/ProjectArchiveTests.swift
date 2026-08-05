import XCTest
import SwiftData
@testable import Flapse

final class ProjectArchiveTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func test_freeImportRejectsArchiveAboveEntryLimit() throws {
        let root = try makePackage(entryCount: 15)

        XCTAssertThrowsError(try ProjectArchive.read(packageAt: root, maximumEntryCount: 14)) { error in
            guard case ProjectArchive.ArchiveError.requiresPro = error else {
                return XCTFail("Expected requiresPro, received \(error)")
            }
        }
    }

    func test_importRejectsVideoPathTraversal() throws {
        let root = try makePackage(entryCount: 1, videoFileName: "../escape.mp4")

        XCTAssertThrowsError(try ProjectArchive.read(packageAt: root)) { error in
            guard case ProjectArchive.ArchiveError.manifestUnreadable = error else {
                return XCTFail("Expected manifestUnreadable, received \(error)")
            }
        }
    }

    func test_importRejectsSymbolicLinkPhoto() throws {
        let entryID = UUID()
        let root = try makePackage(entryIDs: [entryID], hasPhoto: true)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        temporaryURLs.append(external)
        try Data([0x01]).write(to: external)
        let photo = root
            .appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent("\(entryID.uuidString).jpg")
        try FileManager.default.createSymbolicLink(at: photo, withDestinationURL: external)

        XCTAssertThrowsError(try ProjectArchive.read(packageAt: root)) { error in
            guard case ProjectArchive.ArchiveError.manifestUnreadable = error else {
                return XCTFail("Expected manifestUnreadable, received \(error)")
            }
        }
    }

    func test_importRejectsSymbolicLinkMediaDirectory() throws {
        let entryID = UUID()
        let root = try makePackage(entryIDs: [entryID], hasPhoto: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.removeItem(at: photos)
        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryURLs.append(externalDirectory)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(
            to: externalDirectory.appendingPathComponent("\(entryID.uuidString).jpg")
        )
        try FileManager.default.createSymbolicLink(
            at: photos,
            withDestinationURL: externalDirectory
        )

        XCTAssertThrowsError(try ProjectArchive.read(packageAt: root)) { error in
            guard case ProjectArchive.ArchiveError.manifestUnreadable = error else {
                return XCTFail("Expected manifestUnreadable, received \(error)")
            }
        }
    }

    func test_validManifestIsReadAndTitleIsBounded() throws {
        let title = String(repeating: "A", count: 160)
        let root = try makePackage(entryCount: 2, title: "  \(title)  ")

        let imported = try ProjectArchive.read(packageAt: root)

        XCTAssertEqual(imported.entries.count, 2)
        XCTAssertEqual(imported.title.count, 120)
        XCTAssertEqual(imported.title, String(title.prefix(120)))
    }

    @MainActor
    func test_materializePersistsAllBatches() async throws {
        let root = try makePackage(entryCount: 31)
        let imported = try ProjectArchive.read(packageAt: root)
        let container = AppModelContainer.makeInMemory()

        let result = try await ProjectArchive.materialize(imported, into: container)

        let projectID = result.id
        let projects = try container.mainContext.fetch(FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        ))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.entries?.count, 31)
    }

    @MainActor
    func test_exportUsesCleanNameInsideUniqueStagingDirectory() async throws {
        let project = Project(title: "Biz", category: .coupleMode, cadence: .daily)

        let url = try await ProjectArchive.write(project: project)
        temporaryURLs.append(url.deletingLastPathComponent())

        XCTAssertEqual(url.lastPathComponent, "Biz.flapseproject")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("flapse-export-"))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        let imported = try ProjectArchive.read(packageAt: url)
        ProjectArchive.discard(imported)
    }

    @MainActor
    func test_folderExportIsBrowsableAndCanBeImported() async throws {
        let sourceContainer = AppModelContainer.makeInMemory()
        let project = Project(title: "Biz", category: .coupleMode, cadence: .daily)
        let entryID = UUID()
        let videoFileName = VideoEntryStorage.fileName(for: entryID)
        let videoURL = VideoEntryStorage.directory.appendingPathComponent(videoFileName)
        try Data([0x00, 0x01, 0x02]).write(to: videoURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let entry = Entry(
            id: entryID,
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            videoFileName: videoFileName,
            videoDuration: 1.5
        )
        entry.project = project
        sourceContainer.mainContext.insert(project)
        sourceContainer.mainContext.insert(entry)
        try sourceContainer.mainContext.save()

        let url = try await ProjectArchive.write(project: project, format: .folder)
        temporaryURLs.append(url.deletingLastPathComponent())

        XCTAssertEqual(url.lastPathComponent, "Biz - Flapse")
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(values.isDirectory, true)
        let manifestValues = try url.appendingPathComponent("manifest.json")
            .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        XCTAssertEqual(manifestValues.isRegularFile, true)
        XCTAssertGreaterThan(manifestValues.fileSize ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("photos", isDirectory: true).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("videos", isDirectory: true).path
        ))
        XCTAssertGreaterThan(
            (try url.appendingPathComponent("photos/\(entryID.uuidString).jpg")
                .resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0,
            0
        )
        XCTAssertGreaterThan(
            (try url.appendingPathComponent("videos/\(entryID.uuidString).mp4")
                .resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0,
            0
        )

        let imported = try ProjectArchive.read(packageAt: url)
        XCTAssertEqual(imported.title, "Biz")
        XCTAssertEqual(imported.entries.count, 1)
        ProjectArchive.discard(imported)
    }

    @MainActor
    func test_singleFileArchiveRoundTripsPhotoDateAndLocation() async throws {
        let sourceContainer = AppModelContainer.makeInMemory()
        let project = Project(title: "Aktarım", category: .coupleMode, cadence: .weekly)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let entry = Entry(capturedAt: capturedAt, imageData: photoBytes, anchorX: 0.25, anchorY: 0.75)
        entry.latitude = 40.992
        entry.longitude = 29.124
        entry.placeName = "Aydıntepe"
        entry.project = project
        sourceContainer.mainContext.insert(project)
        sourceContainer.mainContext.insert(entry)
        try sourceContainer.mainContext.save()

        let url = try await ProjectArchive.write(project: project)
        temporaryURLs.append(url.deletingLastPathComponent())
        let imported = try ProjectArchive.read(packageAt: url)
        let destinationContainer = AppModelContainer.makeInMemory()
        _ = try await ProjectArchive.materialize(imported, into: destinationContainer)

        let importedEntries = try destinationContainer.mainContext.fetch(FetchDescriptor<Entry>())
        let importedEntry = try XCTUnwrap(importedEntries.first)
        XCTAssertEqual(importedEntry.imageData, photoBytes)
        XCTAssertEqual(importedEntry.capturedAt, capturedAt)
        XCTAssertEqual(importedEntry.latitude, 40.992)
        XCTAssertEqual(importedEntry.longitude, 29.124)
        XCTAssertEqual(importedEntry.placeName, "Aydıntepe")
        XCTAssertEqual(importedEntry.anchorX, 0.25)
        XCTAssertEqual(importedEntry.anchorY, 0.75)
    }

    private func makePackage(
        entryCount: Int,
        title: String = "Test",
        videoFileName: String? = nil
    ) throws -> URL {
        try makePackage(
            entryIDs: (0..<entryCount).map { _ in UUID() },
            title: title,
            hasPhoto: false,
            videoFileName: videoFileName
        )
    }

    private func makePackage(
        entryIDs: [UUID],
        title: String = "Test",
        hasPhoto: Bool,
        videoFileName: String? = nil
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension(ProjectArchive.packageExtension)
        temporaryURLs.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("photos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("videos", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = ProjectArchive.Manifest(
            formatVersion: ProjectArchive.Manifest.currentFormatVersion,
            exportedAt: .now,
            project: .init(
                id: UUID(),
                title: title,
                category: ProjectCategory.other.rawValue,
                cadence: CaptureCadence.daily.rawValue,
                createdAt: .now
            ),
            entries: entryIDs.map {
                .init(
                    id: $0,
                    capturedAt: .now,
                    hasPhoto: hasPhoto,
                    videoFileName: videoFileName,
                    videoDuration: nil,
                    anchorX: nil,
                    anchorY: nil,
                    subjectKindRaw: nil,
                    latitude: nil,
                    longitude: nil,
                    placeName: nil
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return root
    }
}
