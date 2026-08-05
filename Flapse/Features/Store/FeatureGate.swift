import Foundation


/// Uygulamanın premium özellikleri. Hangi özelliğin ücretli olduğunu tek listede toplar.
enum PremiumFeature {
    static let smartAlignmentPreferenceKey = "feature.smartAlignment.enabled"
    static let coupleModePreferenceKey = "feature.coupleMode.enabled"
    static let cloudBackupPreferenceKey = "feature.cloudBackup.enabled"

    case unlimitedProjects
    case smartAlignment
    case cloudBackup
    case coupleMode
    case highResExport

    /// SF Symbol adı — hem paywall hem ayarlar satırlarında kullanılır.
    var iconName: String {
        switch self {
        case .unlimitedProjects: "infinity"
        case .smartAlignment:    "wand.and.stars"
        case .cloudBackup:       "icloud.fill"
        case .coupleMode:        "person.2.fill"
        case .highResExport:     "film"
        }
    }

    var title: String {
        switch self {
        case .unlimitedProjects: String(localized: "Sınırsız proje", bundle: .appLanguage)
        case .smartAlignment:    String(localized: "Akıllı hizalama", bundle: .appLanguage)
        case .cloudBackup:       String(localized: "iCloud yedekleme", bundle: .appLanguage)
        case .coupleMode:        String(localized: "Birlikte Çekim", bundle: .appLanguage)
        case .highResExport:     String(localized: "4K, filigransız export", bundle: .appLanguage)
        }
    }

    var subtitle: String {
        switch self {
        case .unlimitedProjects: String(localized: "İstediğin kadar hikaye takip et", bundle: .appLanguage)
        case .smartAlignment:    String(localized: "Otomatik kare eşleştirme", bundle: .appLanguage)
        case .cloudBackup:       String(localized: "Fotoğrafların hep güvende", bundle: .appLanguage)
        case .coupleMode:        String(localized: "Davet linkiyle aynı projeye birlikte çekin", bundle: .appLanguage)
        case .highResExport:     String(localized: "Paylaşıma hazır video", bundle: .appLanguage)
        }
    }

    /// Pro kullanıcılar için açık/kapalı tercihini saklayan `UserDefaults` anahtarı.
    /// Yalnızca kalıcı tercih tutan özelliklerin bir anahtarı vardır.
    var preferenceKey: String? {
        switch self {
        case .smartAlignment: Self.smartAlignmentPreferenceKey
        case .coupleMode:     Self.coupleModePreferenceKey
        case .cloudBackup:    Self.cloudBackupPreferenceKey
        default:              nil
        }
    }
}

/// Para kazanma (monetization) kurallarının yaşadığı saf, test edilebilir tip.
/// Kuralları arayüze dağıtmak yerine burada toplamak hem testi hem ileride fiyat/limit
/// değişikliklerini kolaylaştırır.
enum FeatureGate {

    /// Ücretsiz katmanda izin verilen en fazla aktif proje sayısı.
    static let freeProjectLimit = 1

    /// Ücretsiz katmanda tek projeye eklenebilecek en fazla çekim (fotoğraf) sayısı.
    /// Bu sınıra ulaşınca yeni çekim için Pro gerekir.
    static let freeEntryLimit = 14

    /// Yeni bir proje oluşturulabilir mi?
    static func canCreateProject(isPro: Bool, currentProjectCount: Int) -> Bool {
        isPro || currentProjectCount < freeProjectLimit
    }

    /// Bu projeye yeni bir çekim eklenebilir mi? Ücretsiz kullanıcı ilk 14 kareye
    /// kadar çekebilir; sonrası Pro ister.
    static func canAddEntry(isPro: Bool, currentEntryCount: Int) -> Bool {
        isPro || currentEntryCount < freeEntryLimit
    }

    /// Bir premium özellik açık mı? Şimdilik hepsi tek kapıdan (Pro aboneliği) açılır.
    static func isUnlocked(_ feature: PremiumFeature, isPro: Bool) -> Bool {
        isPro
    }

    /// Abonelik bittiğinde (veya hiç alınmadığında) projenin yalnızca son 14 karesi
    /// görünür; daha eskiler kilitlenir.
    static func lockedEntryCount(isPro: Bool, totalEntries: Int) -> Int {
        isPro ? 0 : max(0, totalEntries - freeEntryLimit)
    }

    /// 14 kareden büyük projelerde timelapse üretimi Pro ister; ücretsiz ayarlarla bile
    /// oluşturulamaz.
    static func canExportTimelapse(isPro: Bool, entryCount: Int) -> Bool {
        isPro || entryCount <= freeEntryLimit
    }

    /// Ücretsiz katmanda yalnızca EN YENİ proje erişilebilir kalır; eskiler kilitlenir.
    static func unlockedProjectID(isPro: Bool, projects: [(id: UUID, createdAt: Date)]) -> UUID? {
        if isPro { return nil }
        return projects.max(by: { $0.createdAt < $1.createdAt })?.id
    }
}
