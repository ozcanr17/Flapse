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

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "Arşivde manifest.json bulunamadı."
            case .manifestUnreadable:
                return "Arşiv dosyası okunamadı ya da bozuk."
            case .unsupportedVersion(let version):
                return "Bu arşiv (sürüm \(version)) uygulamanın bu sürümüyle desteklenmiyor. Lütfen Flapse'i güncelleyin."
            case .videoMissing:
                return "Arşivde belirtilen bir video dosyası bulunamadı."
            }
        }
    }

    // MARK: - Export: SwiftData'dan düz veri anlık görüntüsü (MainActor)

    struct EntrySnapshot: Sendable {
        let id: UUID
        let capturedAt: Date
        let imageData: Data?
        let videoSourceURL: URL?
        let videoDuration: Double?
        let anchorX: Double?
        let anchorY: Double?
        let subjectKindRaw: String?
        let latitude: Double?
        let longitude: Double?
        let placeName: String?
    }

    struct ProjectSnapshot: Sendable {
        let title: String
        let category: String
        let cadence: String
        let createdAt: Date
        let entries: [EntrySnapshot]
    }

    @MainActor
    static func snapshot(of project: Project) -> ProjectSnapshot {
        let entries = project.sortedEntries.map { entry in
            EntrySnapshot(
                id: entry.id,
                capturedAt: entry.capturedAt,
                imageData: entry.imageData,
                videoSourceURL: entry.videoFileURL,
                videoDuration: entry.videoDuration,
                anchorX: entry.anchorX,
                anchorY: entry.anchorY,
                subjectKindRaw: entry.subjectKindRaw,
                latitude: entry.latitude,
                longitude: entry.longitude,
                placeName: entry.placeName
            )
        }
        return ProjectSnapshot(
            title: project.title,
            category: project.category.rawValue,
            cadence: project.cadence.rawValue,
            createdAt: project.createdAt,
            entries: entries
        )
    }

    /// Anlık görüntüyü diske paketler ve paketin URL'ini döndürür. SwiftData'ya
    /// dokunmadığı için arka plan kuyruğunda çalıştırılabilir. Çağıran, paylaşım
    /// bitince geçici dizini silmekten sorumludur.
    static func write(_ snapshot: ProjectSnapshot) throws -> URL {
        let safeTitle = sanitizedFileName(snapshot.title.isEmpty ? "Proje" : snapshot.title)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathExtension(packageExtension)
        let photosDir = root.appendingPathComponent("photos", isDirectory: true)
        let videosDir = root.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        var entryPayloads: [Manifest.EntryPayload] = []
        entryPayloads.reserveCapacity(snapshot.entries.count)

        for entry in snapshot.entries {
            var hasPhoto = false
            if let imageData = entry.imageData {
                let url = photosDir.appendingPathComponent("\(entry.id.uuidString).jpg")
                try imageData.write(to: url, options: .atomic)
                hasPhoto = true
            }
            var videoFileName: String?
            if let sourceURL = entry.videoSourceURL, FileManager.default.fileExists(atPath: sourceURL.path) {
                let name = "\(entry.id.uuidString).mp4"
                try FileManager.default.copyItem(at: sourceURL, to: videosDir.appendingPathComponent(name))
                videoFileName = name
            }
            entryPayloads.append(Manifest.EntryPayload(
                id: entry.id,
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
                title: snapshot.title,
                category: snapshot.category,
                cadence: snapshot.cadence,
                createdAt: snapshot.createdAt
            ),
            entries: entryPayloads
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)

        return root
    }

    // MARK: - Import

    struct ImportedEntry: Sendable {
        let capturedAt: Date
        let imageData: Data?
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
        let entries: [ImportedEntry]
    }

    /// Paketi okur; fotoğraf baytlarını belleğe alır, video klipleri doğrudan
    /// `VideoEntryStorage`'a kopyalar (SwiftData'ya dokunmadığı için arka planda
    /// çalıştırılabilir). Çağıran, `url` güvenlik kapsamlı bir URL ise erişimi bu
    /// çağrı boyunca açık tutmalıdır.
    static func read(packageAt url: URL) throws -> ImportedProject {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.manifestMissing
        }
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
        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(manifest.formatVersion)
        }

        let photosDir = url.appendingPathComponent("photos", isDirectory: true)
        let videosDir = url.appendingPathComponent("videos", isDirectory: true)

        var entries: [ImportedEntry] = []
        entries.reserveCapacity(manifest.entries.count)

        for payload in manifest.entries {
            let imageData: Data? = payload.hasPhoto
                ? try? Data(contentsOf: photosDir.appendingPathComponent("\(payload.id.uuidString).jpg"))
                : nil

            var newVideoFileName: String?
            if let videoFileName = payload.videoFileName {
                let sourceURL = videosDir.appendingPathComponent(videoFileName)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw ArchiveError.videoMissing
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
                imageData: imageData,
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

        return ImportedProject(
            title: manifest.project.title,
            category: manifest.project.category,
            cadence: manifest.project.cadence,
            createdAt: manifest.project.createdAt,
            entries: entries
        )
    }

    /// `read(packageAt:)` sonucundan SwiftData nesnelerini kurar. Mevcut hiçbir
    /// projenin/çekimin üzerine yazmaz — her zaman yeni kimliklerle, ayrı bir proje
    /// olarak eklenir.
    @MainActor
    @discardableResult
    static func materialize(_ imported: ImportedProject, into context: ModelContext) throws -> Project {
        let category = ProjectCategory(rawValue: imported.category) ?? .other
        let cadence = CaptureCadence(rawValue: imported.cadence) ?? .daily
        let project = Project(
            title: imported.title,
            category: category,
            cadence: cadence,
            createdAt: imported.createdAt
        )
        context.insert(project)

        for payload in imported.entries {
            let entry = Entry(
                capturedAt: payload.capturedAt,
                imageData: payload.imageData,
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
        return project
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
