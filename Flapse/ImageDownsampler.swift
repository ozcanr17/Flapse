import UIKit
import ImageIO

enum ImageDownsampler {

    static func image(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Opak bir kareyi JPEG'e yazarken alfa kanalını düşürür.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` sonucu opak bir fotoğrafta bile alfa
    /// bilgisi taşıyabiliyor; bu haliyle JPEG'e yazınca ImageIO uyarı veriyor
    /// ("trying to save an opaque image with 'AlphaPremulLast'") ve çözümlemede
    /// gereken bellek ikiye katlanıyor. Opak bir bağlama yeniden çizerek bunu önlüyoruz.
    static func opaqueJPEGData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        if let cgImage = image.cgImage {
            switch cgImage.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                return image.jpegData(compressionQuality: compressionQuality)
            default:
                break
            }
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let flattened = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return flattened.jpegData(compressionQuality: compressionQuality)
    }

    static func image(
        from data: Data?,
        maxPixelSize: CGFloat,
        priority: TaskPriority = .userInitiated
    ) async -> UIImage? {
        guard let data else { return nil }
        return await Task.detached(priority: priority) {
            image(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Bellek içi küçük resim önbelleği: aynı kare tekrar tekrar diskten okunup
    /// çözülmesin diye. Önbellek isabetinde `load` hiç çağrılmaz (disk erişimi olmaz).
    static func cachedImage(
        key: String,
        maxPixelSize: CGFloat,
        priority: TaskPriority = .userInitiated,
        load: @escaping @MainActor () -> Data?
    ) async -> UIImage? {
        let fullKey = "\(key)-\(Int(maxPixelSize))" as NSString
        if let hit = ThumbnailCache.shared.object(forKey: fullKey) { return hit }
        guard let decoded = await ThumbnailDecodeCoordinator.shared.image(
            key: fullKey as String,
            maxPixelSize: maxPixelSize,
            priority: priority,
            load: load
        ) else { return nil }
        let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        ThumbnailCache.shared.setObject(decoded, forKey: fullKey, cost: cost)
        return decoded
    }
}

enum ThumbnailCache {
    static let shared = ThumbnailCacheStore()
}

final class ThumbnailCacheStore: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 160
        cache.totalCostLimit = 72 * 1_024 * 1_024
        MemoryWarningObserver.shared.onMemoryWarning = { [weak self] in
            self?.removeAllObjects()
        }
    }

    func object(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func setObject(_ image: UIImage, forKey key: NSString, cost: Int) {
        cache.setObject(image, forKey: key, cost: cost)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

private actor ThumbnailDecodeCoordinator {
    static let shared = ThumbnailDecodeCoordinator()

    private var tasks: [String: Task<UIImage?, Never>] = [:]
    private var activeDecodeCount = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumConcurrentDecodes = 3

    func image(
        key: String,
        maxPixelSize: CGFloat,
        priority: TaskPriority,
        load: @escaping @MainActor () -> Data?
    ) async -> UIImage? {
        if let task = tasks[key] {
            return await task.value
        }
        let task: Task<UIImage?, Never> = Task {
            await acquireDecodeSlot()
            defer { releaseDecodeSlot() }
            guard !Task.isCancelled else { return nil }
            // SwiftData externalStorage erişimi model context'inin aktöründe kalır;
            // fakat slot alındıktan sonra çalıştığı için tüm görünür hücreler aynı
            // anda büyük Data nesneleri yükleyemez.
            guard let data = await load() else { return nil }
            guard !Task.isCancelled else { return nil }
            return await Task.detached(priority: priority) {
                ImageDownsampler.image(from: data, maxPixelSize: maxPixelSize)
            }.value
        }
        tasks[key] = task
        let image = await task.value
        tasks[key] = nil
        return image
    }

    private func acquireDecodeSlot() async {
        if activeDecodeCount < maximumConcurrentDecodes {
            activeDecodeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            slotWaiters.append(continuation)
        }
    }

    private func releaseDecodeSlot() {
        if slotWaiters.isEmpty {
            activeDecodeCount -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }
}

private final class MemoryWarningObserver: @unchecked Sendable {
    static let shared = MemoryWarningObserver()

    var onMemoryWarning: (() -> Void)?
    private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onMemoryWarning?()
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
