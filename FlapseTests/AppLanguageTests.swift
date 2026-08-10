import XCTest
@testable import Flapse

final class AppLanguageTests: XCTestCase {

    override func tearDown() {
        LanguageOverrideBundle.apply(.system)
        super.tearDown()
    }

    func test_overrideBundle_secilenDildeCevirir() {
        LanguageOverrideBundle.apply(.portuguese)
        XCTAssertEqual(String(localized: "Ayarlar", bundle: .appLanguage), "Ajustes")

        LanguageOverrideBundle.apply(.german)
        XCTAssertEqual(String(localized: "Ayarlar", bundle: .appLanguage), "Einstellungen")

        LanguageOverrideBundle.apply(.japanese)
        XCTAssertEqual(String(localized: "Ayarlar", bundle: .appLanguage), "設定")

        LanguageOverrideBundle.apply(.thai)
        XCTAssertEqual(String(localized: "Ayarlar", bundle: .appLanguage), "การตั้งค่า")

        LanguageOverrideBundle.apply(.traditionalChinese)
        XCTAssertEqual(String(localized: "Ayarlar", bundle: .appLanguage), "設定")
    }

    func test_sistemDili_anaPaketeDoner() {
        LanguageOverrideBundle.apply(.system)
        XCTAssertNil(LanguageOverrideBundle.override)
    }

    func test_tumDillerinLprojPaketiVar() {
        for language in AppLanguage.allCases {
            guard let code = language.localeIdentifier else { continue }
            XCTAssertNotNil(
                Bundle.main.path(forResource: code, ofType: "lproj"),
                "\(code).lproj eksik"
            )
        }
    }
}
