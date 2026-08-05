import Foundation
import SwiftData

/// ModelContainer'ı kuran tek yer. İki ayrı "fabrika" sunar: biri gerçek
/// uygulama için (CloudKit'e senkron), biri test ve önizleme için (bellek içi).
enum AppModelContainer {

    struct ProductionResult {
        let container: ModelContainer
        let failureDescription: String?
    }

    /// Hangi modellerin saklanacağını tanımlayan şema. Yeni @Model eklersek
    /// buraya da eklemeyi unutmamamız gerekir.
    private static let schema = Schema([Project.self, Entry.self, SavedTimelapse.self])

    /// iCloud yedekleme, kullanıcının açık tercihine bağlı bir Pro özelliğidir. Anahtar
    /// PremiumFeature.cloudBackup.preferenceKey ile aynıdır; tercih yalnızca Pro
    /// kullanıcı tarafından Ayarlar'dan açılabilir. Değişiklik bir sonraki açılışta geçerli olur.
    static var iCloudBackupEnabled: Bool {
        CloudBackupPreference.isEnabled
    }

    /// Son açılışta CloudKit senkronunun gerçekten aktif olup olmadığı. Ayarlar bunu
    /// gösterir: kullanıcı iCloud'u açtı ama (ör. ücretsiz hesap/entitlement yok) yerel'e
    /// düştüyse durumu görebilir.
    static let iCloudBackupActiveKey = CloudBackupPreference.activeKey

    /// Üretim: yerel diskte saklar. Kullanıcı iCloud yedeklemeyi (Pro) açtıysa ayrıca
    /// kişisel iCloud'una (CloudKit) otomatik senkron eder. CloudKit kurulamazsa uygulama
    /// çökmez; yerel-only depoya düşer.
    static func makeProduction() -> ProductionResult {
        if iCloudBackupEnabled {
            let cloudConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            if let container = try? ModelContainer(for: schema, configurations: [cloudConfiguration]) {
                UserDefaults.standard.set(true, forKey: iCloudBackupActiveKey)
                return ProductionResult(container: container, failureDescription: nil)
            }
        }
        UserDefaults.standard.set(false, forKey: iCloudBackupActiveKey)

        let localConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return ProductionResult(
                container: try ModelContainer(for: schema, configurations: [localConfiguration]),
                failureDescription: nil
            )
        } catch {
            return ProductionResult(
                container: makeInMemory(),
                failureDescription: error.localizedDescription
            )
        }
    }

    /// Test ve SwiftUI önizlemeleri: diske ve CloudKit'e hiç dokunmaz, her seferinde
    /// tertemiz başlar. Testleri hızlı ve birbirinden izole yapan şey budur.
    static func makeInMemory() -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Bellek içi ModelContainer'ı oluşturulamadı: \(error)")
        }
    }
}
