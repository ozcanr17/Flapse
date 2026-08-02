import SwiftUI
import AVFoundation

/// Seçilen parça için "nereden başlasın" seçimi — Instagram/TikTok'taki şarkı
/// kırpma adımına benzer. Zorunlu değildir: müzik seçildiğinde varsayılan olarak
/// baştan çalar, kullanıcı isterse bu ekrandan başlangıç noktasını değiştirir.
struct MusicTrimSheet: View {
    let url: URL
    let title: String
    var initialOffset: Double
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var preview = SoundtrackPreviewPlayer()
    @State private var duration: Double = 0
    @State private var offset: Double = 0
    @State private var isLoading = true

    private let previewID = "trim-preview"
    private let minTrailing: Double = 3

    private var maxOffset: Double {
        max(0, duration - minTrailing)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 6) {
                    Text(title)
                        .font(Theme.headline(18))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text("Videonun müziği burada başlasın")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

                Button {
                    if preview.playingID == previewID {
                        preview.stop()
                    } else {
                        preview.play(id: previewID, url: url, at: offset)
                    }
                } label: {
                    Image(systemName: preview.playingID == previewID ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                VStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { offset },
                            set: { newValue in
                                offset = newValue
                                if preview.playingID == previewID {
                                    preview.seek(to: newValue)
                                }
                            }
                        ),
                        in: 0...max(0.01, maxOffset)
                    )
                    .tint(theme.accent)
                    .disabled(isLoading || maxOffset <= 0)

                    HStack {
                        Text(Self.format(offset))
                        Spacer()
                        Text(Self.format(duration))
                    }
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
                }
                .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        preview.stop()
                        onConfirm(offset)
                        dismiss()
                    } label: {
                        Text("Kullan")
                            .font(Theme.headline(17))
                    }
                    .buttonStyle(.flapsePrimary)
                    .disabled(isLoading)

                    Button {
                        preview.stop()
                        dismiss()
                    } label: {
                        Text("İptal")
                            .font(Theme.body(15))
                            .foregroundStyle(theme.inkMuted)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 20)
            .background(theme.canvas)
            .navigationTitle("Başlangıç Noktası")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") {
                        preview.stop()
                        dismiss()
                    }
                }
            }
        }
        .task {
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            duration = seconds.isFinite ? seconds : 0
            offset = min(initialOffset, max(0, duration - minTrailing))
            isLoading = false
        }
        .onDisappear { preview.stop() }
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
