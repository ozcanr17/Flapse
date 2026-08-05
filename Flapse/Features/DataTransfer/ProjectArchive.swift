import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Bir projeyi kayıpsız şekilde tek bir dizin paketine (`.flapseproject`) aktarır ve
/// aynı formattan geri okur.
///
/// Zip/sıkıştırma kütüphanesi kullanmıyoruz: paket, `Info.plist`'te `public.package`'a
/// uyan bir UTType olarak tanımlı, bu yüzden Dosyalar uygulaması onu tek bir öğe gibi
/// gösterir; sistem paylaşım sayfası da (Mail, Mesajlar) klasörleri gönderirken
/// kendiliğinden sıkıştırır, alıcı taraf Dosyalar'ın yerleşik "Aç" özelliğiyle geri
/// çıkarabilir. SwiftData modeline yalnızca `snapshot(of:)` (MainActor) dokunur; asıl
/// disk I/O'su (`write`, `read`) model'den bağımsız çalışır ve arka planda yürütülebilir.
enum ProjectArchive {

    static let packageExtension = "flapseproject"
    private static let maximumManifestBytes = 5 * 1_024 * 1_024
    private static let maximumArchiveEntries = 10_000
    private static let maximumPhotoBytes = 100 * 1_024 * 1_024
    private static let maximumVideoBytes = 1_024 * 1_024 * 1_024
    private static let maximumTotalMediaBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    private static let importBatchSize = 25

    /// `Info.plist`'teki `UTExportedTypeDeclarations` girdisiyle eşleşir.
    static let utType = UTType(exportedAs: "rozcan.flapse.projectarchive")

    // MARK: - Manifest

    struct Manifest: Codable {
        static let currentFormatVersion = 1

        struct ProjectPayload: Codable {
            var id: UUID
            var title: String
            var category: String
            var cadence: String
            var createdAt: Date
        }

        struct EntryPayload: Codable {
            var id: UUID
            var capturedAt: Date
            var hasPhoto: Bool
            var videoFileName: String?
            var videoDuration: Double?
            var anchorX: Double?
            var anchorY: Double?
            var subjectKindRaw: String?
            var latitude: Double?
            var longitude: Double?
            var placeName: String?
        }

        var formatVersion: Int
        var exportedAt: Date
        var project: ProjectPayload
        var entries: [EntryPayload]
    }

    enum ArchiveError: LocalizedError {
        case manifestMissing
        case manifestUnreadable
        case unsupportedVersion(Int)
        case videoMissing
        case requiresPro

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return String(localized: "Arşivde manifest.json bulunamadı.")
            case .manifestUnreadable:
                return String(localized: "Arşiv dosyası okunamadı ya da bozuk.")
            case .unsupportedVersion(let version):
                return String(localized: "Bu arşiv (sürüm \(version)) uygulamanın bu sürümüyle desteklenmiyor. Lütfen Flapse'i güncelleyin.")
            case .videoMissing:
                return String(localized: "Arşivde belirtilen bir video dosyası bulunamadı.")
            case .requiresPro:
                return nil
            }
        }
    }

    // MARK: - Export

    /// Projeyi paketler ve paketin URL'ini döndürür. Çağıran, paylaşım bitince geçici
    /// dizini silmekten sorumludur.
    ///
    /// Kareler TEK TEK işlenir: her fotoğrafın baytları okunur, diske yazılır ve bir
    /// sonrakine geçmeden serbest bırakılır. Önce hepsini bir diziye toplayan bir sürüm
    /// vardı; `imageData` `.externalStorage` olduğu ve kameradan gelen JPEG'ler tam
    /// çözünürlükte saklandığı için bu, yüzlerce kareli bir projede yüz megabaytları
    /// aynı anda ana aktöre çekiyordu (bkz. HANDOFF'taki `imageData` kuralı).
    @MainActor
    static func write(project: Project) async throws -> URL {
        let safeTitle = sanitizedFileName(project.title.isEmpty ? "Proje" : project.title)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathExtension(packageExtension)
        do {
            try await writeContents(of: project, to: root)
        } catch {
            // Yarım kalan paketi burada silmezsek geçici dizinde kalıcı olur: dışa
            // aktarma sayfası hiç açılmadığından çağıranın temizlik yolu da işlemez.
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return root
    }

    @MainActor
    private static func writeContents(of project: Project, to root: URL) async throws {
        let photosDir = root.appendingPathComponent("photos", isDirectory: true)
        let videosDir = root.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        let entries = project.sortedEntries
        var entryPayloads: [Manifest.EntryPayload] = []
        entryPayloads.reserveCapacity(entries.count)

        for entry in entries {
            let id = entry.id
            var hasPhoto = false
            // Bayt kopyalama ve disk yazımı arka plana veriliyor; `Data` Sendable
            // olduğu için aktör sınırını güvenle geçer ve tur bitince serbest kalır.
            if let imageData = entry.imageData {
                let url = photosDir.appendingPathComponent("\(id.uuidString).jpg")
                try await Task.detached(priority: .userInitiated) {
                    try imageData.write(to: url, options: .atomic)
                }.value
                hasPhoto = true
            }
            var videoFileName: String?
            if let sourceURL = entry.videoFileURL, FileManager.default.fileExists(atPath: sourceURL.path) {
                let name = "\(id.uuidString).mp4"
                let destination = videosDir.appendingPathComponent(name)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }.value
                videoFileName = name
            }
            entryPayloads.append(Manifest.EntryPayload(
                id: id,
                capturedAt: entry.capturedAt,
                hasPhoto: hasPhoto,
                videoFileName: videoFileName,
                videoDuration: entry.videoDuration,
                anchorX: entry.anchorX,
                anchorY: entry.anchorY,
                subjectKindRaw: entry.subjectKindRaw,
                latitude: entry.latitude,
                longitude: entry.longitude,
                placeName: entry.placeName
            ))
        }

        let manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion,
            exportedAt: .now,
            project: Manifest.ProjectPayload(
                id: UUID(),
                title: project.title,
                category: project.category.rawValue,
                cadence: project.cadence.rawValue,
                createdAt: project.createdAt
            ),
            entries: entryPayloads
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = root.appendingPathComponent("manifest.json")
        try await Task.detached(priority: .userInitiated) {
            try manifestData.write(to: manifestURL, options: .atomic)
        }.value
    }

    // MARK: - Import

    struct ImportedEntry: Sendable {
        let capturedAt: Date
        /// Fotoğrafın paket içindeki adı. Baytlar burada TAŞINMAZ; `materialize` her
        /// kareyi sırası gelince okur. Hepsini önce diziye almak, `materialize`'ın da
        /// aynı baytları `Entry`'lere kopyalaması yüzünden tepe belleği arşivin iki
        /// katına çıkarıyordu.
        let photoFileName: String?
        /// Video klibi, okuma sırasında zaten `VideoEntryStorage`'a kopyalanmıştır —
        /// burada yalnızca dosya adı taşınır, `materialize` ek I/O yapmaz.
        let videoFileName: String?
        let videoDuration: Double?
        let anchorX: Double?
        let anchorY: Double?
        let subjectKindRaw: String?
        let latitude: Double?
        let longitude: Double?
        let placeName: String?
    }

    struct ImportedProject: Sendable {
        let title: String
        let category: String
        let cadence: String
        let createdAt: Date
        /// `materialize` fotoğrafları buradan okur, bu yüzden çağıran güvenlik kapsamlı
        /// erişimi `materialize` bitene kadar da açık tutmalıdır.
        let packageURL: URL
        let entries: [ImportedEntry]
    }

    struct MaterializedProject: Sendable {
        let id: UUID
        let title: String
    }

    /// Paketin manifest'ini okur ve video kliplerini `VideoEntryStorage`'a kopyalar.
    /// Fotoğraf baytlarına dokunmaz — onları `materialize` tek tek okur. SwiftData'ya
    /// dokunmadığı için arka planda çalıştırılabilir. Çağıran, `url` güvenlik kapsamlı
    /// bir URL ise erişimi `materialize` bitene kadar açık tutmalıdır.
    static func read(packageAt url: URL, maximumEntryCount: Int? = nil) throws -> ImportedProject {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard let manifestSize = regularFileSize(at: manifestURL) else {
            throw ArchiveError.manifestMissing
        }
        guard manifestSize <= maximumManifestBytes else { throw ArchiveError.manifestUnreadable }
        let data: Data
        let manifest: Manifest
        do {
            data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(Manifest.self, from: data)
        } catch {
            throw ArchiveError.manifestUnreadable
        }
        guard manifest.formatVersion == Manifest.currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.entries.count <= maximumArchiveEntries else {
            throw ArchiveError.manifestUnreadable
        }
        if let maximumEntryCount, manifest.entries.count > maximumEntryCount {
            throw ArchiveError.requiresPro
        }

        let photosDir = url.appendingPathComponent("photos", isDirectory: true)
        let videosDir = url.appendingPathComponent("videos", isDirectory: true)
        if manifest.entries.contains(where: \.hasPhoto), !isSafeDirectory(at: photosDir) {
            throw ArchiveError.manifestUnreadable
        }
        if manifest.entries.contains(where: { $0.videoFileName != nil }), !isSafeDirectory(at: videosDir) {
            throw ArchiveError.manifestUnreadable
        }

        var entries: [ImportedEntry] = []
        entries.reserveCapacity(manifest.entries.count)
        var totalMediaBytes: Int64 = 0

        do {
            for payload in manifest.entries {
                var photoFileName: String?
                if payload.hasPhoto {
                    let name = "\(payload.id.uuidString).jpg"
                    let photoURL = photosDir.appendingPathComponent(name)
                    if let size = regularFileSize(at: photoURL), size <= maximumPhotoBytes {
                        totalMediaBytes += Int64(size)
                        guard totalMediaBytes <= maximumTotalMediaBytes else {
                            throw ArchiveError.manifestUnreadable
                        }
                        photoFileName = name
                    } else {
                        throw ArchiveError.manifestUnreadable
                    }
                }

                var newVideoFileName: String?
                if let videoFileName = payload.videoFileName {
                    guard isSafeVideoFileName(videoFileName) else {
                        throw ArchiveError.manifestUnreadable
                    }
                    let sourceURL = videosDir.appendingPathComponent(videoFileName)
                    guard let size = regularFileSize(at: sourceURL), size <= maximumVideoBytes else {
                        throw ArchiveError.videoMissing
                    }
                    totalMediaBytes += Int64(size)
                    guard totalMediaBytes <= maximumTotalMediaBytes else {
                        throw ArchiveError.manifestUnreadable
                    }
                    let destName = VideoEntryStorage.fileName(for: UUID())
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: VideoEntryStorage.directory.appendingPathComponent(destName)
                    )
                    newVideoFileName = destName
                }

                entries.append(ImportedEntry(
                    capturedAt: payload.capturedAt,
                    photoFileName: photoFileName,
                    videoFileName: newVideoFileName,
                    videoDuration: payload.videoDuration,
                    anchorX: payload.anchorX,
                    anchorY: payload.anchorY,
                    subjectKindRaw: payload.subjectKindRaw,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    placeName: payload.placeName
                ))
            }
        } catch {
            // Klipler VideoEntryStorage'a, yani SwiftData'nın dışına kopyalanıyor;
            // okuma yarıda kalırsa onları hiçbir kayıt işaret etmez ve kalıcı olarak
            // yer kaplarlar.
            discardCopiedVideos(in: entries)
            throw error
        }

        return ImportedProject(
            title: String(manifest.project.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
            category: manifest.project.category,
            cadence: manifest.project.cadence,
            createdAt: manifest.project.createdAt,
            packageURL: url,
            entries: entries
        )
    }

    /// `read(packageAt:)` sonucundan SwiftData nesnelerini kurar. Mevcut hiçbir
    /// projenin/çekimin üzerine yazmaz — her zaman yeni kimliklerle, ayrı bir proje
    /// olarak eklenir.
    @discardableResult
    static func materialize(
        _ imported: ImportedProject,
        into container: ModelContainer
    ) async throws -> MaterializedProject {
        try await Task.detached(priority: .userInitiated) {
            let category = ProjectCategory(rawValue: imported.category) ?? .other
            let cadence = CaptureCadence(rawValue: imported.cadence) ?? .daily
            let projectID = UUID()

            do {
                let projectContext = ModelContext(container)
                projectContext.autosaveEnabled = false
                projectContext.insert(Project(
                    id: projectID,
                    title: imported.title,
                    category: category,
                    cadence: cadence,
                    createdAt: imported.createdAt
                ))
                try projectContext.save()

                let photosDirectory = imported.packageURL
                    .appendingPathComponent("photos", isDirectory: true)
                for start in stride(from: 0, to: imported.entries.count, by: importBatchSize) {
                    try Task.checkCancellation()
                    let end = min(start + importBatchSize, imported.entries.count)
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    let descriptor = FetchDescriptor<Project>(
                        predicate: #Predicate { $0.id == projectID }
                    )
                    guard let project = try context.fetch(descriptor).first else {
                        throw ArchiveError.manifestUnreadable
                    }
                    for payload in imported.entries[start..<end] {
                        let imageData: Data?
                        if let photoFileName = payload.photoFileName {
                            imageData = try Data(
                                contentsOf: photosDirectory.appendingPathComponent(photoFileName),
                                options: .mappedIfSafe
                            )
                        } else {
                            imageData = nil
                        }
                        let entry = Entry(
                            capturedAt: payload.capturedAt,
                            imageData: imageData,
                            anchorX: payload.anchorX,
                            anchorY: payload.anchorY,
                            subjectKindRaw: payload.subjectKindRaw,
                            videoFileName: payload.videoFileName,
                            videoDuration: payload.videoDuration
                        )
                        entry.latitude = payload.latitude
                        entry.longitude = payload.longitude
                        entry.placeName = payload.placeName
                        entry.project = project
                        context.insert(entry)
                    }
                    try context.save()
                }

                return MaterializedProject(id: projectID, title: imported.title)
            } catch {
                let cleanupContext = ModelContext(container)
                cleanupContext.autosaveEnabled = false
                let descriptor = FetchDescriptor<Project>(
                    predicate: #Predicate { $0.id == projectID }
                )
                if let project = try? cleanupContext.fetch(descriptor).first {
                    cleanupContext.delete(project)
                    try? cleanupContext.save()
                }
                discardCopiedVideos(in: imported.entries)
                throw error
            }
        }.value
    }

    /// İçe aktarma yarıda kaldığında `VideoEntryStorage`'a kopyalanmış klipleri siler.
    private static func discardCopiedVideos(in entries: [ImportedEntry]) {
        for name in entries.compactMap(\.videoFileName) {
            try? FileManager.default.removeItem(
                at: VideoEntryStorage.directory.appendingPathComponent(name)
            )
        }
    }

    private static func regularFileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return values.fileSize
    }

    private static func isSafeDirectory(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isSafeVideoFileName(_ name: String) -> Bool {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/"), !name.contains("\\") else { return false }
        let url = URL(fileURLWithPath: name)
        return url.pathExtension.lowercased() == "mp4"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    /// `.fileExporter`'a önerilen dosya adı olarak verilir (uzantısız — `contentType`
    /// zaten `.flapseproject` uzantısını ekler).
    static func sanitizedExportName(_ title: String) -> String {
        sanitizedFileName(title)
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Proje" : String(trimmed.prefix(60))
    }
}
