import Foundation
import UIKit

enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case bug
    case idea
    case improvement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug:         String(localized: "Hata", bundle: .appLanguage)
        case .idea:        String(localized: "Yeni özellik", bundle: .appLanguage)
        case .improvement: String(localized: "İyileştirme", bundle: .appLanguage)
        }
    }

    var icon: String {
        switch self {
        case .bug:         "exclamationmark.triangle"
        case .idea:        "lightbulb"
        case .improvement: "wand.and.stars"
        }
    }

    var prompt: String {
        switch self {
        case .bug:
            String(localized: "Ne oldu? Hangi adımlardan sonra karşılaştın?", bundle: .appLanguage)
        case .idea:
            String(localized: "Hangi özelliği eklemek isterdin?", bundle: .appLanguage)
        case .improvement:
            String(localized: "Neyi daha iyi yapabiliriz?", bundle: .appLanguage)
        }
    }
}

/// Kullanıcının geliştiriciye gönderdiği bulgu. Mesajın yanında, hatayı
/// tekrarlayabilmek için gereken en az teknik bağlam taşınır — kişisel veri
/// içermez, iletişim e-postası isteğe bağlıdır.
struct FeedbackReport: Sendable, Equatable {
    let kind: FeedbackKind
    let message: String
    let contactEmail: String
    let appVersion: String
    let systemVersion: String
    let deviceModel: String
    let locale: String
    let createdAt: Date

    static let minimumMessageLength = 10

    static func isValid(message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumMessageLength
    }

    @MainActor
    static func make(
        kind: FeedbackKind,
        message: String,
        contactEmail: String,
        now: Date = .now
    ) -> FeedbackReport {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return FeedbackReport(
            kind: kind,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            contactEmail: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            appVersion: "\(version) (\(build))",
            systemVersion: "iOS \(UIDevice.current.systemVersion)",
            deviceModel: Self.hardwareIdentifier,
            locale: Locale.current.identifier,
            createdAt: now
        )
    }

    /// `UIDevice.model` yalnızca "iPhone" döndürür; hangi modelde olduğunu bilmek
    /// hata ayıklamada belirleyici olduğu için donanım tanımlayıcısını okuyoruz.
    private static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// CloudKit'e ulaşılamadığında kullanılan e-posta gövdesi.
    var mailBody: String {
        """
        \(message)

        ---
        \(kind.title)
        \(appVersion) · \(systemVersion) · \(deviceModel) · \(locale)
        """
    }
}
