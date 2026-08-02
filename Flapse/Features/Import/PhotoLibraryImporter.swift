import Foundation
import Photos
import UIKit
import ImageIO
import CoreLocation
import AVFoundation

struct PhotoImportSource {
    let assetIdentifier: String?
    let selectionIndex: Int
    let load: () async -> Data?
    /// Doluysa bu kaynak bir video klibidir: `load` çağrılmaz, klip doğrudan
    /// geçici bir dosya URL'i olarak alınıp `VideoEntryStorage`'a kopyalanır
    /// (video verisini `Data` olarak belleğe yüklemekten kaçınmak için).
    var loadVideoFile: (() async -> URL?)? = nil

    var isVideo: Bool { loadVideoFile != nil }
}

@MainActor
protocol PhotoLibraryImporting {
    func buildEntries(
        from sources: [PhotoImportSource],
        maxPixelSize: CGFloat,
        progress: @escaping (Double) -> Void
    ) async -> [Entry]
}

extension PhotoLibraryImporting {
    func buildEntries(from sources: [PhotoImportSource], progress: @escaping (Double) -> Void) async -> [Entry] {
        await buildEntries(from: sources, maxPixelSize: 2560, progress: progress)
    }
}

@MainActor
final class PhotoLibraryImporter: PhotoLibraryImporting {

    private enum LoadedMedia {
        case photo(Data)
        case video(fileName: String, duration: Double, poster: Data?)
    }

    func buildEntries(
        from sources: [PhotoImportSource],
        maxPixelSize: CGFloat,
        progress: @escaping (Double) -> Void
    ) async -> [Entry] {
        guard !sources.isEmpty else { return [] }

        let meta = libraryMeta(for: sources.compactMap(\.assetIdentifier))

        var loaded: [(id: String, index: Int, media: LoadedMedia, date: Date?, location: CLLocation?)] = []
        loaded.reserveCapacity(sources.count)

        for (offset, source) in sources.enumerated() {
            let identifier = source.assetIdentifier ?? UUID().uuidString
            let assetMeta = source.assetIdentifier.flatMap { meta[$0] }
            if source.isVideo, let loadVideoFile = source.loadVideoFile {
                guard let tempURL = await loadVideoFile() else { continue }
                let entryID = UUID()
                let fileName = VideoEntryStorage.fileName(for: entryID)
                let destination = VideoEntryStorage.directory.appendingPathComponent(fileName)
                guard (try? await Self.moveVideo(from: tempURL, to: destination)) != nil else { continue }
                let duration = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
                let poster = await Self.videoPoster(at: destination)
                let date = assetMeta?.date ?? Date()
                loaded.append((identifier, source.selectionIndex, .video(fileName: fileName, duration: duration, poster: poster), date, assetMeta?.location))
            } else {
                guard let data = await source.load() else { continue }
                let date = assetMeta?.date ?? Self.exifDate(from: data)
                let location = assetMeta?.location ?? Self.exifLocation(from: data)
                loaded.append((identifier, source.selectionIndex, .photo(data), date, location))
            }
            progress(Double(offset + 1) / Double(sources.count) * 0.5)
        }

        let items = loaded.map {
            PhotoImportItem(assetIdentifier: $0.id, creationDate: $0.date, selectionIndex: $0.index)
        }
        let resolved = PhotoImportPlan.resolvedOrder(items)
        let byIdentifier = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [Entry] = []
        entries.reserveCapacity(resolved.count)
        for (offset, item) in resolved.enumerated() {
            guard let source = byIdentifier[item.assetIdentifier] else { continue }
            let entry: Entry
            switch source.media {
            case .photo(let data):
                guard let downsampled = await downsample(data, maxPixelSize: maxPixelSize) else { continue }
                entry = Entry(capturedAt: item.date, imageData: downsampled, sourceAssetIdentifier: item.assetIdentifier)
            case .video(let fileName, let duration, let poster):
                entry = Entry(
                    capturedAt: item.date,
                    imageData: poster,
                    sourceAssetIdentifier: item.assetIdentifier,
                    videoFileName: fileName,
                    videoDuration: duration
                )
            }
            if let location = source.location {
                entry.latitude = location.coordinate.latitude
                entry.longitude = location.coordinate.longitude
            }
            entries.append(entry)
            progress(0.5 + Double(offset + 1) / Double(resolved.count) * 0.5)
        }
        return entries
    }

    private static func moveVideo(from tempURL: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: tempURL, to: destination)
        }.value
    }

    private static func videoPoster(at url: URL) async -> Data? {
        await CameraCaptureViewModel.posterData(for: url)
    }

    private func libraryMeta(for identifiers: [String]) -> [String: (date: Date?, location: CLLocation?)] {
        guard !identifiers.isEmpty else { return [:] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [:] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var map: [String: (date: Date?, location: CLLocation?)] = [:]
        assets.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = (asset.creationDate, asset.location)
        }
        return map
    }

    static func exifLocation(from data: Data) -> CLLocation? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
            let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return CLLocation(
            latitude: latRef == "S" ? -latitude : latitude,
            longitude: lonRef == "W" ? -longitude : longitude
        )
    }

    private func downsample(_ data: Data, maxPixelSize: CGFloat) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            ImageDownsampler.image(from: data, maxPixelSize: maxPixelSize)?
                .jpegData(compressionQuality: 0.9)
        }.value
    }

    static func exifDate(from data: Data) -> Date? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        return exifFormatter.date(from: raw)
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
