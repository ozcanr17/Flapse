import SwiftUI

/// Kaydırılan içeriğin üstte sert bir eşikte kesilmesini önleyen kademeli geçiş.
///
/// Projeler'de başlık sabit olduğu için içerik onun altından görünmeden geçmeli;
/// Ana Sayfa ve Kaydedilenler'de ise içerik durum çubuğuna kadar çıkıp saat ve pil
/// göstergesiyle çakışıyordu. İkisini de aynı yumuşak geçişle çözüyoruz.
struct ScrollEdgeFade: View {

    var height: CGFloat = 96
    @Environment(\.theme) private var theme

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: theme.canvas, location: 0),
                .init(color: theme.canvas, location: 0.55),
                .init(color: theme.canvas.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
    }
}
