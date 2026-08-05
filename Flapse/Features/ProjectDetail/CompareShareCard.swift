import SwiftUI

struct CompareShareCard: View {
    let title: String
    let firstImage: UIImage
    let lastImage: UIImage
    let firstDate: Date
    let lastDate: Date
    let theme: ThemePalette

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: firstDate, to: lastDate).day ?? 1)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.canvas, theme.surface, theme.accent.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 32) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 52, weight: .bold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                        Text("Önce & Sonra Kartı")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(theme.inkMuted)
                    }
                    Spacer()
                    LogoMark(size: 68)
                }

                HStack(spacing: 16) {
                    panel(image: firstImage, label: String(localized: "GÜN 1", bundle: .appLanguage), date: firstDate)
                    panel(image: lastImage, label: String(localized: "BUGÜN", bundle: .appLanguage), date: lastDate)
                }
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(dayCount)")
                            .font(.system(size: 62, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("GÜN", bundle: .appLanguage)
                            .font(.system(size: 17, weight: .bold))
                            .tracking(3)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(.black.opacity(0.72), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                }

                HStack {
                    Image(systemName: "camera.aperture")
                    Text("Flapse ile takip ediyorum")
                    Spacer()
                    Text(firstDate, format: .dateTime.year().locale(AppLanguage.currentLocale))
                    Image(systemName: "arrow.right")
                    Text(lastDate, format: .dateTime.year().locale(AppLanguage.currentLocale))
                }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.inkMuted)
            }
            .padding(50)
        }
        .frame(width: 1080, height: 1350)
        .clipped()
    }

    private func panel(image: UIImage, label: String, date: Date) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 482, height: 930)
            .clipped()
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(1.8)
                    Text(date, format: .dateTime.day().month(.wide).year().locale(AppLanguage.currentLocale))
                        .font(.system(size: 16, weight: .semibold))
                        .opacity(0.86)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
            }
    }
}
