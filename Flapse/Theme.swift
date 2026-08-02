import SwiftUI
import UIKit

struct ThemePalette: Equatable {
    let accent: Color
    let secondary: Color
    let canvas: Color
    let surface: Color
    let ink: Color
    let inkMuted: Color
    var isGlass: Bool = false
    var glow: Color? = nil
}

enum AppTheme: String, CaseIterable, Identifiable {
    case filmNegative = "film_negative"
    case paper
    case coastal
    case cyber
    case darkroom
    case fjord

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .filmNegative: String(localized: "Negatif", bundle: .appLanguage)
        case .cyber:        String(localized: "Grafit", bundle: .appLanguage)
        case .darkroom:     String(localized: "Karanlık Oda", bundle: .appLanguage)
        case .fjord:        String(localized: "Fiyort", bundle: .appLanguage)
        case .paper:        String(localized: "Kâğıt", bundle: .appLanguage)
        case .coastal:      String(localized: "Sahil", bundle: .appLanguage)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .filmNegative, .paper, .coastal: .light
        case .fjord, .cyber, .darkroom: .dark
        }
    }

    static func resolved(storedID: String) -> AppTheme {
        if let exact = AppTheme(rawValue: storedID) { return exact }
        switch storedID {
        case "daylight": return .coastal
        case "bright": return .paper
        case "lavender": return .filmNegative
        default: return .filmNegative
        }
    }

    var palette: ThemePalette {
        switch self {
        case .filmNegative:
            ThemePalette(
                accent: Color(hex: "2E8B57"),
                secondary: Color(hex: "1F6B6E"),
                canvas: Color(hex: "F3F0EA"),
                surface: Color(hex: "FFFFFF"),
                ink: Color(hex: "241F1B"),
                inkMuted: Color(hex: "6E675E")
            )
        case .cyber:
            ThemePalette(
                accent: Color(hex: "6FA8DC"),
                secondary: Color(hex: "9AA4B2"),
                canvas: Color(hex: "0F1115"),
                surface: Color(hex: "1A1D23"),
                ink: Color(hex: "F2F3F5"),
                inkMuted: Color(hex: "9AA0A8")
            )
        case .darkroom:
            ThemePalette(
                accent: Color(hex: "E3A23B"),
                secondary: Color(hex: "C4574A"),
                canvas: Color(hex: "121110"),
                surface: Color(hex: "1F1C18"),
                ink: Color(hex: "F4EDE1"),
                inkMuted: Color(hex: "9A9187")
            )
        case .fjord:
            ThemePalette(
                accent: Color(hex: "88BDE6"),
                secondary: Color(hex: "80C29D"),
                canvas: Color(hex: "0D1820"),
                surface: Color(hex: "172832"),
                ink: Color(hex: "EDF6F8"),
                inkMuted: Color(hex: "9BB0B7")
            )
        case .paper:
            ThemePalette(
                accent: Color(hex: "A43B34"),
                secondary: Color(hex: "2F5D50"),
                canvas: Color(hex: "F6F0E4"),
                surface: Color(hex: "FFFBF2"),
                ink: Color(hex: "1E1A17"),
                inkMuted: Color(hex: "746B61")
            )
        case .coastal:
            ThemePalette(
                accent: Color(hex: "007C91"),
                secondary: Color(hex: "D96B35"),
                canvas: Color(hex: "EAF6F7"),
                surface: Color(hex: "FBFFFF"),
                ink: Color(hex: "14343A"),
                inkMuted: Color(hex: "627D80")
            )
        }
    }
}

struct ThemeConfiguration: Equatable {
    let palette: ThemePalette
    let preferredColorScheme: ColorScheme
}

enum ThemePreference {
    static let customEnabledKey = "customTheme.enabled"
    static let primaryHexKey = "customTheme.primaryHex"
    static let secondaryHexKey = "customTheme.secondaryHex"
    static let defaultPrimaryHex = "F3F0EA"
    static let defaultSecondaryHex = "2E8B57"

    static func configuration(
        themeID: String,
        customEnabled: Bool,
        primaryHex: String,
        secondaryHex: String
    ) -> ThemeConfiguration {
        guard customEnabled else {
            let theme = AppTheme.resolved(storedID: themeID)
            return ThemeConfiguration(
                palette: theme.palette,
                preferredColorScheme: theme.preferredColorScheme ?? .light
            )
        }

        let primary = UIColor(hex: normalized(primaryHex, fallback: defaultPrimaryHex))
        let accent = UIColor(hex: normalized(secondaryHex, fallback: defaultSecondaryHex))
        let isDark = primary.relativeLuminance < 0.42
        let surface = primary.blended(with: .white, fraction: isDark ? 0.09 : 0.68)
        let secondary = accent.blended(with: isDark ? .white : .black, fraction: 0.2)

        return ThemeConfiguration(
            palette: ThemePalette(
                accent: Color(uiColor: accent),
                secondary: Color(uiColor: secondary),
                canvas: Color(uiColor: primary),
                surface: Color(uiColor: surface),
                ink: Color(hex: isDark ? "F5F5F7" : "17171A"),
                inkMuted: Color(hex: isDark ? "B3B3BB" : "66666E"),
                glow: Color(uiColor: accent)
            ),
            preferredColorScheme: isDark ? .dark : .light
        )
    }

    private static func normalized(_ hex: String, fallback: String) -> String {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else { return fallback }
        return cleaned
    }
}

extension EnvironmentValues {
    @Entry var theme: ThemePalette = AppTheme.filmNegative.palette
}

enum Theme {

    static let brand = Color(light: "2E8B57", dark: "5FD98A")

    private static let categoryAccents: [ProjectCategory: Color] = [
        .selfPortrait: Color(light: "2E8B57", dark: "5FD98A"),
        .person:       Color(light: "5E5CE6", dark: "9D9BF5"),
        .child:        Color(light: "B8637A", dark: "E79CAE"),
        .plant:        Color(light: "4C7A52", dark: "8FC79A"),
        .hairAndBeard: Color(light: "8A6A4E", dark: "C9A97D"),
        .pet:          Color(light: "5B7FBF", dark: "94B4F2"),
        .fitness:      Color(light: "B0722E", dark: "E0A468"),
        .pregnancy:    Color(light: "9A5BA6", dark: "C99BD6"),
        .baby:         Color(light: "3E8E9E", dark: "7FC3D1"),
        .outfit:       Color(light: "B0568A", dark: "D98BB8"),
        .coupleMode:   Color(light: "C2566B", dark: "F191A6"),
        .video:        Color(light: "5B6B8A", dark: "9AAAD1"),
        .other:        Color(light: "6E675E", dark: "B3ABA0")
    ]

    static func accent(for category: ProjectCategory) -> Color {
        categoryAccents[category] ?? categoryAccents[.other]!
    }

    static func icon(for category: ProjectCategory) -> String {
        switch category {
        case .selfPortrait: "person.crop.circle"
        case .person:       "person.fill"
        case .child:        "figure.child"
        case .plant:        "leaf.fill"
        case .hairAndBeard: "scissors"
        case .pet:          "pawprint.fill"
        case .fitness:      "dumbbell.fill"
        case .pregnancy:    "figure.stand"
        case .baby:         "stroller.fill"
        case .outfit:       "tshirt.fill"
        case .coupleMode:   "person.2.fill"
        case .video:        "video.fill"
        case .other:        "sparkles"
        }
    }

    static func headline(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
    static func stamp(_ size: CGFloat = 15, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let cornerRadius: CGFloat = 20
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }

    var hexRGB: String? {
        let color = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }

    init(light: String, dark: String) {
        self.init(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    func mix(with other: Color, by fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: ar + (br - ar) * f,
            green: ag + (bg - ag) * f,
            blue: ab + (bb - ab) * f,
            opacity: aa + (ba - aa) * f
        )
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }

    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }

        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func blended(with other: UIColor, fraction: CGFloat) -> UIColor {
        let amount = min(max(fraction, 0), 1)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: &otherAlpha) else {
            return self
        }
        return UIColor(
            red: red + (otherRed - red) * amount,
            green: green + (otherGreen - green) * amount,
            blue: blue + (otherBlue - blue) * amount,
            alpha: alpha + (otherAlpha - alpha) * amount
        )
    }
}

struct LiquidGlassStyle<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    var scrimOpacity: Double = 0
    var clear: Bool = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(theme.surface))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(theme.inkMuted.opacity(0.16), lineWidth: 0.5)
                }
        } else if #available(iOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(glass, in: shape)
        } else {
            content
                .background {
                    if let tint {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(tint)
                        }
                        .overlay {
                            LinearGradient(
                                colors: [.white.opacity(0.06), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                            .clipShape(shape)
                        }
                    } else {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            if scrimOpacity > 0 {
                                shape.fill(theme.surface.opacity(scrimOpacity))
                            }
                        }
                        .overlay {
                            shape.strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.05), .white.opacity(0.16)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        }
                    }
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass: Glass = clear ? .clear : .regular
        if let tint {
            glass = glass.tint(tint)
        } else if scrimOpacity > 0 {
            glass = glass.tint(theme.surface.opacity(scrimOpacity))
        }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.liquidGlassStyle()
    }
}

extension View {
    func liquidGlassStyle(
        cornerRadius: CGFloat = Theme.cornerRadius,
        tint: Color? = nil,
        interactive: Bool = false,
        scrimOpacity: Double = 0,
        clear: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassStyle(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                interactive: interactive,
                scrimOpacity: scrimOpacity,
                clear: clear
            )
        )
    }

    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false, scrimOpacity: Double = 0, clear: Bool = false) -> some View {
        modifier(LiquidGlassStyle(shape: Capsule(), tint: tint, interactive: interactive, scrimOpacity: scrimOpacity, clear: clear))
    }

    func liquidGlassCircle(tint: Color? = nil, interactive: Bool = false, scrimOpacity: Double = 0, clear: Bool = false) -> some View {
        modifier(LiquidGlassStyle(shape: Circle(), tint: tint, interactive: interactive, scrimOpacity: scrimOpacity, clear: clear))
    }

    func liquidGlassBar(cornerRadius: CGFloat = Theme.cornerRadius, interactive: Bool = false) -> some View {
        liquidGlassStyle(cornerRadius: cornerRadius, interactive: interactive, scrimOpacity: 0.08)
    }

    func liquidGlassBarCapsule(interactive: Bool = false) -> some View {
        liquidGlassCapsule(interactive: interactive, scrimOpacity: 0.08)
    }

    func liquidGlassBarCircle(interactive: Bool = false) -> some View {
        liquidGlassCircle(interactive: interactive, scrimOpacity: 0.08)
    }

    func cardStyle() -> some View { modifier(CardBackground()) }
    func glassSurface(cornerRadius: CGFloat = 18, tint: Color) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }
}

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape.fill(tint)
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.06), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                        .clipShape(shape)
                    }
            }
            .clipShape(shape)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline(17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .liquidGlassStyle(
                cornerRadius: 14,
                tint: isEnabled ? theme.accent : theme.inkMuted.opacity(0.4),
                interactive: isEnabled
            )
            .shadow(color: .black.opacity(isEnabled ? 0.12 : 0), radius: 8, x: 0, y: 3)
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.6))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.18), value: isEnabled)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var flapsePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

struct GlassIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassIconButtonStyle {
    static var glassIcon: GlassIconButtonStyle { GlassIconButtonStyle() }
}
