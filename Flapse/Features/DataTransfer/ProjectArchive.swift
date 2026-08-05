import AppleArchive
import Foundation
import SwiftData
import System
import UniformTypeIdentifiers

/// Bir projeyi kayıpsız şekilde, kullanıcının seçimine göre Dosyalar'da gezilebilir
/// bir klasöre veya sıkıştırılmış tek bir `.flapseproject` dosyasına aktarır. İçe
/// aktarma iki biçimi de otomatik tanır.
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

    enum ExportFormat: Sendable, Equatable {
        /// `manifest.json`, `photos/` ve `videos/` Dosyalar'da doğrudan görülebilir.
        case folder
        /// AirDrop/Mail/Mesajlar için tek, sıkıştırılmış `.flapseproject` dosyası.
        case singleFile
    }

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

    /// Kareler TEK TEK işlenir: her fotoğrafın baytları okunur, diske yazılır ve bir
    /// sonrakine geçmeden serbest bırakılır. Önce hepsini bir diziye toplayan bir sürüm
    /// vardı; `imageData` `.externalStorage` olduğu ve kameradan gelen JPEG'ler tam
    /// çözünürlükte saklandığı için bu, yüzlerce kareli bir projede yüz megabaytları
    /// aynı anda ana aktöre çekiyordu (bkz. HANDOFF'taki `imageData` kuralı).
    @MainActor
    static func write(project: Project, format: ExportFormat = .singleFile) async throws -> URL {
        let safeTitle = sanitizedFileName(project.title.isEmpty ? "Proje" : project.title)
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-export-\(UUID().uuidString)", isDirectory: true)
        let outputURL: URL
        switch format {
        case .folder:
            // Özel uzantı kullanırsak Files klasörü yeniden belge/paket gibi
            // gösterebilir. Uzantısız klasör, medya alt klasörlerinin gezilmesini sağlar.
            outputURL = stagingDirectory
                .appendingPathComponent("\(safeTitle) - Flapse", isDirectory: true)
        case .singleFile:
            outputURL = stagingDirectory
                .appendingPathComponent(safeTitle, isDirectory: false)
                .appendingPathExtension(packageExtension)
        }
        do {
            switch format {
            case .folder:
                try await writeContents(of: project, to: outputURL)
            case .singleFile:
                let payloadDirectory = stagingDirectory
                    .appendingPathComponent("payload", isDirectory: true)
                try await writeContents(of: project, to: payloadDirectory)
                try await Task.detached(priority: .userInitiated) {
                    try compress(directory: payloadDirectory, to: outputURL)
                    guard let size = regularFileSize(at: outputURL), size > 0 else {
                        throw ArchiveError.manifestUnreadable
                    }
                    try FileManager.default.removeItem(at: payloadDirectory)
                }.value
            }
            if format == .folder {
                let manifestURL = outputURL.appendingPathComponent("manifest.json")
                guard regularFileSize(at: manifestURL) != nil else {
                    throw ArchiveError.manifestUnreadable
                }
            }
        } catch {
            // Yarım kalan paketi burada silmezsek geçici dizinde kalıcı olur: dışa
            // aktarma sayfası hiç açılmadığından çağıranın temizlik yolu da işlemez.
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
        return outputURL
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
        /// Tek-dosya arşiv içe aktarılırken açılan geçici klasör. `materialize`
        /// tamamlandığında (başarılı ya da hatalı) mutlaka temizlenir.
        let cleanupDirectoryURL: URL?
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
        let resolved = try resolvedPackageURL(for: url)
        do {
            return try readDirectoryPackage(
                at: resolved.packageURL,
                cleanupDirectoryURL: resolved.cleanupDirectoryURL,
                maximumEntryCount: maximumEntryCount
            )
        } catch {
            if let cleanupDirectoryURL = resolved.cleanupDirectoryURL {
                try? FileManager.default.removeItem(at: cleanupDirectoryURL)
            }
            throw error
        }
    }

    private static func readDirectoryPackage(
        at url: URL,
        cleanupDirectoryURL: URL?,
        maximumEntryCount: Int?
    ) throws -> ImportedProject {
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
            cleanupDirectoryURL: cleanupDirectoryURL,
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
            defer {
                if let cleanupDirectoryURL = imported.cleanupDirectoryURL {
                    try? FileManager.default.removeItem(at: cleanupDirectoryURL)
                }
            }
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

    /// Başarıyla okunmuş bir arşiv materialize edilmeden iptal edilirse çağrılır.
    /// Eski klasör paketlerine dokunmaz; yalnızca uygulamanın açtığı geçici kopyayı siler.
    static func discard(_ imported: ImportedProject) {
        if let cleanupDirectoryURL = imported.cleanupDirectoryURL {
            try? FileManager.default.removeItem(at: cleanupDirectoryURL)
        }
        discardCopiedVideos(in: imported.entries)
    }

    // MARK: - Single-file container

    private struct ResolvedPackage {
        let packageURL: URL
        let cleanupDirectoryURL: URL?
    }

    /// Eski klasör paketini doğrudan, yeni tek dosyayı ise güvenli bir geçici
    /// klasöre açarak ortak manifest doğrulama yoluna yönlendirir.
    private static func resolvedPackageURL(for url: URL) throws -> ResolvedPackage {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw ArchiveError.manifestUnreadable }
        if values?.isDirectory == true {
            return ResolvedPackage(packageURL: url, cleanupDirectoryURL: nil)
        }
        guard values?.isRegularFile == true else { throw ArchiveError.manifestUnreadable }

        let extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("flapse-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            try extract(archiveAt: url, to: extractionRoot)
            return ResolvedPackage(packageURL: extractionRoot, cleanupDirectoryURL: extractionRoot)
        } catch {
            try? FileManager.default.removeItem(at: extractionRoot)
            throw ArchiveError.manifestUnreadable
        }
    }

    /// AppleArchive LZFSE akışı JPEG/video gibi zaten sıkıştırılmış medyayı gereksiz
    /// yere belleğe almadan, dosya dosya tek bir fiziksel arşive yazar.
    private static func compress(directory: URL, to outputURL: URL) throws {
        try ArchiveByteStream.withFileStream(
            path: FilePath(outputURL.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite]
        ) { fileStream in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: fileStream) { compressedStream in
                try ArchiveStream.withEncodeStream(writingTo: compressedStream) { archiveStream in
                    try archiveStream.writeDirectoryContents(
                        archiveFrom: FilePath(directory.path),
                        keySet: .defaultForArchive
                    )
                }
            }
        }
    }

    private static func extract(archiveAt archiveURL: URL, to directory: URL) throws {
        try ArchiveByteStream.withFileStream(
            path: FilePath(archiveURL.path),
            mode: .readOnly,
            options: [],
            permissions: []
        ) { fileStream in
            try ArchiveByteStream.withDecompressionStream(readingFrom: fileStream) { decompressedStream in
                try ArchiveStream.withDecodeStream(
                    readingFrom: decompressedStream,
                    selectUsing: { _, path, data in
                        guard isSafeArchivePath(path) else { return .cancel }
                        if case .header(let header) = data,
                           header.entryType != .regularFile,
                           header.entryType != .directory {
                            return .cancel
                        }
                        return .ok
                    }
                ) { decodeStream in
                    try ArchiveStream.withExtractStream(extractingTo: FilePath(directory.path)) { extractStream in
                        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
                    }
                }
            }
        }
    }

    /// Arşiv açılmadan önce yalnızca beklenen iki seviyeli göreli yolları kabul eder.
    /// Böylece manifest doğrulamasına ulaşmadan önce path traversal/link yazılamaz.
    private static func isSafeArchivePath(_ path: FilePath) -> Bool {
        guard path.isRelative, path.isLexicallyNormal else { return false }
        let components = path.components.map(\.string)
        guard !components.isEmpty, components.count <= 2,
              !components.contains("."), !components.contains("..") else { return false }
        switch components[0] {
        case "manifest.json":
            return components.count == 1
        case "photos", "videos":
            return true
        default:
            return false
        }
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

    private static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Proje" : String(trimmed.prefix(60))
    }
}
