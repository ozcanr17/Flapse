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
                return String(localized: "Arşivde manifest.json bulunamadı.")
            case .manifestUnreadable:
                return String(localized: "Arşiv dosyası okunamadı ya da bozuk.")
            case .unsupportedVersion(let version):
                return String(localized: "Bu arşiv (sürüm \(version)) uygulamanın bu sürümüyle desteklenmiyor. Lütfen Flapse'i güncelleyin.")
            case .videoMissing:
                return String(localized: "Arşivde belirtilen bir video dosyası bulunamadı.")
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

    /// Paketin manifest'ini okur ve video kliplerini `VideoEntryStorage`'a kopyalar.
    /// Fotoğraf baytlarına dokunmaz — onları `materialize` tek tek okur. SwiftData'ya
    /// dokunmadığı için arka planda çalıştırılabilir. Çağıran, `url` güvenlik kapsamlı
    /// bir URL ise erişimi `materialize` bitene kadar açık tutmalıdır.
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

        do {
            for payload in manifest.entries {
                var photoFileName: String?
                if payload.hasPhoto {
                    let name = "\(payload.id.uuidString).jpg"
                    if FileManager.default.fileExists(atPath: photosDir.appendingPathComponent(name).path) {
                        photoFileName = name
                    }
                }

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
            title: manifest.project.title,
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

        let photosDir = imported.packageURL.appendingPathComponent("photos", isDirectory: true)
        var inserted: [Entry] = []
        inserted.reserveCapacity(imported.entries.count)
        for payload in imported.entries {
            let imageData = payload.photoFileName.flatMap {
                try? Data(contentsOf: photosDir.appendingPathComponent($0))
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
            inserted.append(entry)
        }

        do {
            try context.save()
        } catch {
            // Kayıt başarısızsa `read` sırasında kopyalanan klipleri kimse sahiplenmez.
            // Bağlam uygulamanın ana bağlamı olduğu için `rollback()` yerine yalnızca
            // kendi eklediklerimizi geri alıyoruz; başkasının bekleyen değişikliği varsa
            // ona dokunmuyoruz.
            for entry in inserted { context.delete(entry) }
            context.delete(project)
            discardCopiedVideos(in: imported.entries)
            throw error
        }
        return project
    }

    /// İçe aktarma yarıda kaldığında `VideoEntryStorage`'a kopyalanmış klipleri siler.
    private static func discardCopiedVideos(in entries: [ImportedEntry]) {
        for name in entries.compactMap(\.videoFileName) {
            try? FileManager.default.removeItem(
                at: VideoEntryStorage.directory.appendingPathComponent(name)
            )
        }
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
