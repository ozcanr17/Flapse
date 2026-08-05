import Foundation
import UIKit

/// Uygulama içi dil seçimi. `system` cihaz dilini izler; diğerleri uygulamayı anında
/// o dile geçirir — Ayarlar'a gitmeden, veri kaybı olmadan.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case turkish = "tr"
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case portuguese = "pt"
    case hindi = "hi"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case arabic = "ar"
    case russian = "ru"
    case korean = "ko"

    static let storageKey = "app.language"

    var id: String { rawValue }

    /// Her dil kendi adında gösterilir — yanlışlıkla dil değiştiren biri bile tanıyabilsin.
    var nativeName: String {
        switch self {
        case .system:     String(localized: "Sistem dili", bundle: .appLanguage)
        case .turkish:    "Türkçe"
        case .english:    "English"
        case .german:     "Deutsch"
        case .spanish:    "Español"
        case .french:     "Français"
        case .portuguese: "Português"
        case .hindi:      "हिन्दी"
        case .chinese:    "简体中文"
        case .japanese:   "日本語"
        case .arabic:     "العربية"
        case .russian:    "Русский"
        case .korean:     "한국어"
        }
    }

    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    var isRightToLeft: Bool {
        self == .arabic
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// Tarih/sayı biçimlemeleri için seçili dilin Locale'i (sistemde cihaz dili).
    static var currentLocale: Locale {
        current.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }
}

extension Bundle {
    /// `String(localized:bundle:)` çağrılarının seçili uygulama dilini izlemesi için
    /// kullanılacak paket: dil geçersiz kılınmışsa o dilin .lproj'u, değilse ana paket.
    static var appLanguage: Bundle {
        LanguageOverrideBundle.override ?? .main
    }
}

/// `String(localized:)` çağrılarının da seçilen dili izlemesi için Bundle.main'in
/// yerelleştirme aramasını seçili dilin .lproj paketine yönlendirir.
final class LanguageOverrideBundle: Bundle, @unchecked Sendable {

    static let overrideKey = "app.language.bundle"

    nonisolated(unsafe) static var override: Bundle?

    static func activate() {
        object_setClass(Bundle.main, LanguageOverrideBundle.self)
        apply(AppLanguage.current)
    }

    static func apply(_ language: AppLanguage) {
        guard
            let code = language.localeIdentifier,
            let path = Bundle.main.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            override = nil
            objc_setAssociatedObject(Bundle.main, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        override = bundle
        objc_setAssociatedObject(Bundle.main, &associationKey, bundle, .OBJC_ASSOCIATION_RETAIN)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &associationKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

nonisolated(unsafe) private var associationKey: UInt8 = 0
