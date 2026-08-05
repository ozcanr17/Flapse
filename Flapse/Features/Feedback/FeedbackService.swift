import CloudKit
import Foundation

protocol FeedbackSubmitting: Sendable {
    func submit(_ report: FeedbackReport) async throws
}

enum FeedbackError: Error {
    case notSignedIntoiCloud
    case unavailable
}

/// Bulgular, uygulamanın hâlihazırda kullandığı CloudKit kabının **genel (public)**
/// veritabanına yazılır. Geliştirici bunları CloudKit Dashboard → Records → `Feedback`
/// altında görür; ayrı bir sunucu, hesap ya da üçüncü taraf servis gerekmez.
///
/// Genel veritabanına yazmak iCloud oturumu gerektirir; oturum yoksa ya da ağ
/// erişilemiyorsa çağıran taraf e-posta yoluna düşer (bkz. `FeedbackViewModel`).
struct CloudKitFeedbackService: FeedbackSubmitting {

    static let recordType = "Feedback"

    static let containerIdentifier = "iCloud.rozcan.Flapse"

    /// CloudKit'e hiç dokunulmaması gereken süreçler (UI testleri) için: imzasız bir
    /// süreçte CKContainer oluşturmak hata döndürmek yerine SIGTRAP üretebilir.
    static var isEnabledForCurrentProcess: Bool {
        !ProcessInfo.processInfo.arguments.contains("--uitests")
            && ProcessInfo.processInfo.environment["FLAPSE_UI_TESTS"] != "1"
    }

    private let containerIdentifier: String

    init(containerIdentifier: String = CloudKitFeedbackService.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    func submit(_ report: FeedbackReport) async throws {
        guard Self.isEnabledForCurrentProcess else { throw FeedbackError.unavailable }

        let container = CKContainer(identifier: containerIdentifier)
        let status = try? await container.accountStatus()
        guard status == .available else { throw FeedbackError.notSignedIntoiCloud }

        let record = CKRecord(recordType: Self.recordType)
        record["kind"] = report.kind.rawValue as CKRecordValue
        record["message"] = report.message as CKRecordValue
        record["appVersion"] = report.appVersion as CKRecordValue
        record["systemVersion"] = report.systemVersion as CKRecordValue
        record["deviceModel"] = report.deviceModel as CKRecordValue
        record["createdAt"] = report.createdAt as CKRecordValue
        if !report.contactEmail.isEmpty {
            record["contactEmail"] = report.contactEmail as CKRecordValue
        }

        try await container.publicCloudDatabase.save(record)
    }
}

enum FeedbackMailer {

    /// App Store'da da yayımlanan destek adresi. CloudKit'e ulaşılamazsa bulgu
    /// buraya hazır doldurulmuş bir e-postayla gönderilir.
    static let supportEmail = "ridvanozcan7@gmail.com"

    static func mailURL(for report: FeedbackReport) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Flapse · \(report.kind.title)"),
            URLQueryItem(name: "body", value: report.mailBody)
        ]
        return components.url
    }
}
