import SwiftUI
import Observation

/// Kamera açılışında iki ekran arasındaki boşluğu dolduran geçiş göstergesi.
///
/// Kamera oturumu artık ~20-70 ms'de hazır oluyor; görünen bekleme, çekim düğmesine
/// basılmasıyla kamera ekranının belirmesi arasındaki sunum/oluşturma süresinden
/// geliyor (cihazda ölçülen: ~1.2-1.5 sn). O aralıkta kullanıcı donmuş bir arayüze
/// bakmak yerine uygulamanın açılış logosunun aynısını dönerken görür.
@MainActor
@Observable
final class CameraLaunchIndicator {

    static let shared = CameraLaunchIndicator()

    private(set) var isVisible = false
    private var autoHideTask: Task<Void, Never>?

    /// Beklenmedik bir durumda göstergenin ekranda takılı kalmaması için üst sınır.
    private static let safetyTimeout: Duration = .seconds(4)

    func show() {
        autoHideTask?.cancel()
        isVisible = true
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.safetyTimeout)
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        isVisible = false
    }
}

/// Açılış ekranındaki logonun aynısı: yalnızca içteki objektif döner.
/// `repeatForever` yerine `TimelineView` kullanılıyor — uygulama arka plana alınıp
/// geri gelince "biriken" animasyonun sıçramasını önler.
struct CameraLaunchOverlay: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 2.4

    var body: some View {
        ZStack {
            theme.canvas.ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
                LogoMark(size: 96, innerRotation: .degrees(Self.angle(at: timeline.date)))
            }
        }
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel(Text("Kamera açılıyor", bundle: .appLanguage))
    }

    private static func angle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return (t / period) * 360
    }
}
