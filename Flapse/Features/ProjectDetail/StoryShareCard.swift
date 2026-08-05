import SwiftUI

struct StoryShareCard: View {
    let title: String
    let firstImage: UIImage
    let lastImage: UIImage
    let firstDate: Date
    let lastDate: Date
    let theme: ThemePalette

    private var dayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0) + 1)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.canvas, theme.accent.opacity(0.22), theme.secondary.opacity(0.32)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 28) {
                HStack(spacing: 18) {
                    LogoMark(size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 42, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("Flapse")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(theme.inkMuted)
                    }
                    Spacer()
                }
                .foregroundStyle(theme.ink)

                panel(image: firstImage, label: String(localized: "GÜN 1", bundle: .appLanguage), date: firstDate)

                HStack(spacing: 22) {
                    Rectangle()
                        .fill(theme.inkMuted.opacity(0.3))
                        .frame(height: 1)
                    VStack(spacing: 2) {
                        Text("\(dayCount)")
                            .font(.system(size: 72, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("GÜN", bundle: .appLanguage)
                            .font(.system(size: 18, weight: .bold))
                            .tracking(4)
                    }
                    .foregroundStyle(theme.ink)
                    Rectangle()
                        .fill(theme.inkMuted.opacity(0.3))
                        .frame(height: 1)
                }

                panel(image: lastImage, label: String(localized: "BUGÜN", bundle: .appLanguage), date: lastDate)

                HStack {
                    Image(systemName: "camera.aperture")
                    Text("Flapse ile takip ediyorum")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 64)
        }
        .frame(width: 1080, height: 1920)
        .clipped()
    }

    private func panel(image: UIImage, label: String, date: Date) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 968, height: 650)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(label)
                            .font(.system(size: 27, weight: .heavy))
                            .tracking(2)
                        Text(date, format: .dateTime.day().month(.wide).year().locale(AppLanguage.currentLocale))
                            .font(.system(size: 20, weight: .semibold))
                            .opacity(0.86)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(26)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            }
    }
}
