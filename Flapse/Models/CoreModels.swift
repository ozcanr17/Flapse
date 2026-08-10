import Foundation
import SwiftData

// MARK: - Enum'lar

/// Projenin neyi takip ettiğini belirtir. String tabanlı olduğu için SwiftData ve
/// CloudKit bunu sorunsuz saklar; CaseIterable sayesinde arayüzde seçim listesi
/// olarak gösterebiliriz.
enum ProjectCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case selfPortrait = "self"
    case person
    case child
    case plant
    case hairAndBeard = "hair_beard"
    case pet
    case fitness
    case pregnancy
    case baby
    case outfit
    case interiorDecor = "interior_decor"
    case coupleMode = "capture_together"
    case video
    case other

    var id: String { rawValue }

    /// Kullanıcıya gösterilecek okunabilir ad. (switch-as-expression: Swift 5.9+)
    var displayName: String {
        switch self {
        case .selfPortrait: String(localized: "Kendim", bundle: .appLanguage)
        case .person:       String(localized: "Kişi", bundle: .appLanguage)
        case .child:        String(localized: "Çocuk", bundle: .appLanguage)
        case .plant:        String(localized: "Bitki", bundle: .appLanguage)
        case .hairAndBeard: String(localized: "Saç & Sakal", bundle: .appLanguage)
        case .pet:          String(localized: "Evcil hayvan", bundle: .appLanguage)
        case .fitness:      String(localized: "Fitness", bundle: .appLanguage)
        case .pregnancy:    String(localized: "Hamilelik", bundle: .appLanguage)
        case .baby:         String(localized: "Bebek", bundle: .appLanguage)
        case .outfit:       String(localized: "Kombin", bundle: .appLanguage)
        case .interiorDecor: String(localized: "Mekân & Dekorasyon", bundle: .appLanguage)
        case .coupleMode:   String(localized: "Çift Modu", bundle: .appLanguage)
        case .video:        String(localized: "Video", bundle: .appLanguage)
        case .other:        String(localized: "Diğer", bundle: .appLanguage)
        }
    }

    /// "Çift Modu" bir Pro kategorisidir: iki kişi aynı karede, bölme kılavuzuyla.
    var isPro: Bool { self == .coupleMode }

    /// Video modunda hizalama (ghost/smart/manual) uygulanmaz; medya doğrudan
    /// video klip olarak eklenir ve dışa aktarımda sırayla birleştirilir.
    var isVideoMode: Bool { self == .video }
}

/// Çekim sıklığı (kadans). Hatırlatıcıların ve "çekim zamanı geldi mi?" mantığının
/// temelini oluşturur.
enum CaptureCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily
    case everyOtherDay = "every_other_day"
    case weekly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily:         String(localized: "Her gün", bundle: .appLanguage)
        case .everyOtherDay: String(localized: "Gün aşırı", bundle: .appLanguage)
        case .weekly:        String(localized: "Haftalık", bundle: .appLanguage)
        case .monthly:       String(localized: "Aylık", bundle: .appLanguage)
        }
    }

    /// İki çekim arasındaki gün sayısı. `.monthly` gerçek ay uzunluğuna göre
    /// değişir (28-31 gün); burada yalnızca kaba bir yaklaşık değer döner —
    /// gerçek hesap `nextDueDate(after:calendar:)` içindeki takvim-ay ekleme
    /// dalından gelir.
    var dayInterval: Int {
        switch self {
        case .daily:         1
        case .everyOtherDay: 2
        case .weekly:        7
        case .monthly:       30
        }
    }

    /// Son çekimden sonra bir sonraki çekimin beklendiği gün.
    func nextDueDate(after lastCapture: Date, calendar: Calendar = .current) -> Date {
        if self == .monthly {
            return calendar.date(byAdding: .month, value: 1, to: lastCapture) ?? lastCapture
        }
        return calendar.date(byAdding: .day, value: dayInterval, to: lastCapture) ?? lastCapture
    }

    /// `now` anı itibarıyla yeni bir çekimin zamanı geldi mi?
    ///
    /// `now` ve `calendar` parametre olarak alınır (varsayılanları var). Böylece
    /// üretimde `Date()` ile çağırırız, testte ise sabit bir tarih enjekte ederek
    /// sonucu deterministik (her makinede aynı) hale getiririz. Bu, test edilebilir
    /// kod yazmanın en pratik tekniklerinden biri.
    func isCaptureDue(lastCapture: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        // Hiç çekim yapılmamışsa ilk çekim her zaman beklenebilir.
        guard let lastCapture else { return true }
        let due = nextDueDate(after: lastCapture, calendar: calendar)
        // Saat farklarından etkilenmemek için gün başlangıçlarını karşılaştırıyoruz.
        return calendar.startOfDay(for: now) >= calendar.startOfDay(for: due)
    }
}

// MARK: - Modeller

/// Tek bir çekim: bir fotoğraf + ne zaman çekildiği + hizalama referansı.
@Model
final class Entry {
    // CloudKit eşitlemesi için: her alanın varsayılan değeri var.
    var id: UUID = UUID()
    var capturedAt: Date = Date()

    // Büyük görsel veri kaydın içine gömülmez. `.externalStorage` ile SwiftData
    // bunu ayrı bir dosyaya yazar; CloudKit'e gittiğinde otomatik olarak CKAsset'e
    // dönüşür. Performans ve maliyet için kritik tercih.
    @Attribute(.externalStorage) var imageData: Data?
    var imageRevision: Int = 0

    // Video modu: gerçek klip `Application Support/EntryVideos/<videoFileName>`
    // altında dosya olarak saklanır (SwiftData/CloudKit blob'una gömülmez, bkz.
    // VideoEntryStorage). `imageData` video girdilerinde ilk karenin poster'ıdır;
    // mevcut grid/timeline/ghost kodları bu sayede değişmeden çalışır.
    var videoFileName: String?
    var videoDuration: Double?

    // "Ghost" hizalaması için referans noktası. 0...1 aralığında NORMALIZE koordinat
    // tutuyoruz; böylece farklı çözünürlüklerde bile aynı yere denk gelir.
    var anchorX: Double?
    var anchorY: Double?

    var sourceAssetIdentifier: String?
    var subjectKindRaw: String?
    @Attribute(.externalStorage) var featurePrintData: Data?

    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var deletedAt: Date?
    var sharedUpdatedAt: Date?
    var sharedImageUpdatedAt: Date?

    // Ait olduğu proje. Ters ilişki (inverse) Project tarafında tanımlı.
    // CloudKit kısıtı gereği optional.
    var project: Project?

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        imageData: Data? = nil,
        anchorX: Double? = nil,
        anchorY: Double? = nil,
        sourceAssetIdentifier: String? = nil,
        subjectKindRaw: String? = nil,
        featurePrintData: Data? = nil,
        videoFileName: String? = nil,
        videoDuration: Double? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.imageData = imageData
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.sourceAssetIdentifier = sourceAssetIdentifier
        self.subjectKindRaw = subjectKindRaw
        self.featurePrintData = featurePrintData
        self.videoFileName = videoFileName
        self.videoDuration = videoDuration
    }

    var imageCacheKey: String {
        "\(id.uuidString)-\(imageRevision)"
    }

    var isVideo: Bool { videoFileName != nil }

    /// Video klibinin diskteki tam konumu (varsa).
    var videoFileURL: URL? {
        guard let videoFileName else { return nil }
        return VideoEntryStorage.directory.appendingPathComponent(videoFileName)
    }
}

/// Video modu klipleri için dosya tabanlı depolama. Fotoğraflardaki `.externalStorage`
/// deseninin aksine, onlarca MB'a çıkabilen video klipleri SwiftData/CloudKit blob'u
/// olarak tutmuyoruz — `TimelapseLibrary.directory`'yle aynı yaklaşım: diskte ayrı
/// bir dizin, model yalnızca dosya adını saklar.
enum VideoEntryStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EntryVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func fileName(for entryID: UUID) -> String {
        "\(entryID.uuidString).mp4"
    }
}

/// Bir takip projesi (ör. "Sakal", "Limon fidanı"). Birden çok Entry içerir.
@Model
final class Project {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()

    // SwiftData, Codable enum'ları doğrudan saklayabilir — ayrıca String'e çevirmemize
    // gerek yok. Varsayılan değer CloudKit için gerekli.
    var category: ProjectCategory = ProjectCategory.other
    var cadence: CaptureCadence = CaptureCadence.daily

    // Birlikte Çekim: arkadaşları davet edip aynı projeye birlikte çekim yaptığında
    // açılır. CloudKit için varsayılan değeri var.
    var isCollaborative: Bool = false

    var cloudShareRecordName: String?
    var cloudRootRecordName: String?
    var cloudZoneName: String?
    var cloudOwnerName: String?
    var cloudPurgedEntryIDsRaw: String?
    var collaboratorNamesRaw: String?
    var sharedUpdatedAt: Date?

    // "Son Silinenler": silinme anı. Dolu ise proje çöp kutusundadır; 30 gün sonra
    // kalıcı silinir. CloudKit ile eşitlenir, iCloud açıkken orada da saklanır.
    var deletedAt: Date?
    var isHidden: Bool = false

    var collaboratorNames: [String] {
        (collaboratorNamesRaw ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var cloudPurgedEntryIDs: Set<UUID> {
        get {
            Set((cloudPurgedEntryIDsRaw ?? "")
                .split(separator: "\n")
                .compactMap { UUID(uuidString: String($0)) })
        }
        set {
            cloudPurgedEntryIDsRaw = newValue
                .map(\.uuidString)
                .sorted()
                .joined(separator: "\n")
        }
    }

    // Bir proje silinince çekimleri de silinsin: .cascade.
    // CloudKit kısıtı gereği to-many ilişki optional olmak zorunda.
    @Relationship(deleteRule: .cascade, inverse: \Entry.project)
    var entries: [Entry]? = []

    // MARK: Hesaplanan (computed) yardımcılar — saklanmaz, anlık türetilir.

    /// Çekimler kronolojik sırada (en eski → en yeni). Timelapse bu sırayla üretilir.
    var sortedEntries: [Entry] {
        (entries ?? [])
            .filter { !$0.isDeleted && $0.deletedAt == nil }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// En son çekimin tarihi (hiç yoksa nil).
    var lastCaptureDate: Date? {
        (entries ?? []).lazy
            .filter { !$0.isDeleted && $0.deletedAt == nil }
            .map(\.capturedAt)
            .max()
    }

    var lastActivityDate: Date {
        max(createdAt, lastCaptureDate ?? createdAt)
    }

    /// "Çift Modu" projesi mi? Kamerada bölme kılavuzunu bu belirler.
    var isCoupleMode: Bool { category == .coupleMode }

    /// Bu proje için yeni çekim zamanı geldi mi? Mantığı CaptureCadence'e devrediyoruz.
    func isCaptureDue(now: Date = Date()) -> Bool {
        cadence.isCaptureDue(lastCapture: lastCaptureDate, now: now)
    }

    init(
        id: UUID = UUID(),
        title: String,
        category: ProjectCategory = .other,
        cadence: CaptureCadence = .daily,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.cadence = cadence
        self.createdAt = createdAt
    }
}
