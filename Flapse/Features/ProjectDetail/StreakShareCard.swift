import SwiftUI

struct StreakShareCard: View {
    let title: String
    let categoryName: String
    let heroImage: UIImage?
    let streak: Int
    let total: Int
    let daysRunning: Int
    let theme: ThemePalette

    var body: some View {
        ZStack {
            background

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.16), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    LogoMark(size: 58)
                    Text("Flapse")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(categoryName.uppercased())
                        .font(.system(size: 15, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.82))
                }

                Spacer()

                Text(title)
                    .font(.system(size: 66, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(streak)")
                        .font(.system(size: 142, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("GÜN SERİSİ")
                        .font(.system(size: 25, weight: .bold))
                        .tracking(4)
                        .padding(.bottom, 24)
                }
                .foregroundStyle(.white)
                .padding(.top, 18)

                HStack(spacing: 16) {
                    stat(value: total, label: "TOPLAM KARE", icon: "photo.stack.fill")
                    stat(value: daysRunning, label: "GÜNDÜR", icon: "calendar")
                }
                .padding(.top, 22)
            }
            .padding(64)
        }
        .frame(width: 1080, height: 1350)
        .clipped()
    }

    @ViewBuilder
    private var background: some View {
        if let heroImage {
            Image(uiImage: heroImage)
                .resizable()
                .scaledToFill()
                .frame(width: 1080, height: 1350)
                .clipped()
        } else {
            LinearGradient(
                colors: [theme.accent, theme.secondary, theme.accent.mix(with: .black, by: 0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func stat(value: Int, label: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.8)
                    .opacity(0.72)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
