import SwiftUI
import XCTest
@testable import Flapse

final class AppThemeTests: XCTestCase {

    func test_tumTemalar_rawValueIleGeriYuklenebilir() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(AppTheme(rawValue: theme.rawValue), theme)
        }
    }

    func test_temaVurgulari_birbirindenFarklidir() {
        let accents = AppTheme.allCases.map(\.palette.accent)
        XCTAssertEqual(Set(accents).count, AppTheme.allCases.count)
    }

    func test_varsayilanTema_filmNegatifidir() {
        XCTAssertEqual(AppTheme(rawValue: "film_negative"), .filmNegative)
    }

    func test_altiHazirTema_ucAcikUcKoyuOlarakDagilir() {
        XCTAssertEqual(AppTheme.allCases.count, 6)
        let lightThemes = AppTheme.allCases.filter { $0.preferredColorScheme == .light }
        let darkThemes = AppTheme.allCases.filter { $0.preferredColorScheme == .dark }
        XCTAssertEqual(lightThemes.count, 3)
        XCTAssertEqual(darkThemes.count, 3)
    }

    func test_eskiTemaKimlikleri_enYakinYeniPaleteTasinir() {
        XCTAssertEqual(AppTheme.resolved(storedID: "daylight"), .coastal)
        XCTAssertEqual(AppTheme.resolved(storedID: "bright"), .paper)
        XCTAssertEqual(AppTheme.resolved(storedID: "lavender"), .filmNegative)
    }

    func test_ozelTema_birincilVeIkincilRenkleriUygular() {
        let configuration = ThemePreference.configuration(
            themeID: AppTheme.filmNegative.rawValue,
            customEnabled: true,
            primaryHex: "101820",
            secondaryHex: "FF6B6B"
        )

        XCTAssertEqual(configuration.preferredColorScheme, .dark)
        XCTAssertEqual(configuration.palette.canvas.hexRGB, "101820")
        XCTAssertEqual(configuration.palette.accent.hexRGB, "FF6B6B")
    }

    func test_hazirTemalar_metinKontrastiWcagAAEsiginiKarsilar() {
        for theme in AppTheme.allCases {
            let palette = theme.palette
            for background in [palette.canvas, palette.surface] {
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(palette.ink, background),
                    4.5,
                    "\(theme.rawValue) ana metin kontrastı yetersiz"
                )
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(palette.inkMuted, background),
                    4.5,
                    "\(theme.rawValue) ikincil metin kontrastı yetersiz"
                )
            }
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.accentForeground, palette.accent),
                4.5,
                "\(theme.rawValue) birincil düğme kontrastı yetersiz"
            )
        }
    }

    private func contrastRatio(_ first: Color, _ second: Color) -> CGFloat {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: Color) -> CGFloat {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
