import SwiftUI

struct WelcomeView: View {

    let onFinish: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            theme.canvas.ignoresSafeArea()
            AnimatedAccentBackground(base: theme.accent)
                .opacity(isAnimating ? 0.14 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 0) {
                    LogoMark(size: 96)
                        .rotationEffect(.degrees(isAnimating || reduceMotion ? 0 : -120))
                        .scaleEffect(isAnimating || reduceMotion ? 1 : 0.6)
                        .opacity(isAnimating ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.7), value: isAnimating)
                        .padding(.top, 32)

                    Text("Flapse")
                        .font(.largeTitle.bold())
                        .foregroundStyle(theme.ink)
                        .padding(.top, 16)

                    Text("Değişimi kare kare biriktir")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.inkMuted)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 16) {
                        WelcomeFeatureRow(
                            icon: "wand.and.stars",
                            title: "Akıllı hizalama",
                            subtitle: "Önceki karen kameranın üzerinde silik görünür; videoda kareler otomatik hizalanır"
                        )
                        WelcomeFeatureRow(
                            icon: "calendar.badge.clock",
                            title: "Ritmini koru",
                            subtitle: "Günlük, gün aşırı ya da haftalık — zamanı gelince hatırlatırız"
                        )
                        WelcomeFeatureRow(
                            icon: "film.stack",
                            title: "Tek dokunuşla timelapse",
                            subtitle: "Karelerin akıcı bir videoya dönüşsün; anında paylaş"
                        )
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                    .padding(.horizontal, 24)
                    .padding(.top, 28)

                    Text("Fotoğrafların cihazında kalır; sen istemeden hiçbir yere gönderilmez.")
                        .font(.footnote)
                        .foregroundStyle(theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
                .opacity(isAnimating ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(0.15), value: isAnimating)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Başla") {
                onFinish()
                dismiss()
            }
                .buttonStyle(.flapsePrimary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(
                    LinearGradient(colors: [theme.canvas.opacity(0), theme.canvas],
                                   startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
                )
        }
        .onAppear { isAnimating = true }
    }
}

private struct WelcomeFeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.1)).frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    WelcomeView {}
}
