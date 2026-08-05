import SwiftUI
import AVFoundation

/// Timelapse render edildikten SONRA müziğin videoyla senkronunu ayarlama ekranı —
/// sosyal medya uygulamalarındaki gibi, gerçek videoyu izlerken müziği kaydırarak
/// ayarlayabilirsiniz. Yalnızca ses yeniden muxlanır; görsel render tekrarlanmaz,
/// bu yüzden anında sonuç verir.
struct PostRenderSyncSheet: View {
    let videoURL: URL
    let soundtrackURL: URL
    var initialOffset: Double
    let onConfirm: (URL, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var player = AVPlayer()
    @State private var offset: Double = 0
    @State private var musicDuration: Double = 0
    @State private var videoDuration: Double = 0
    @State private var isPreparing = true
    @State private var isExporting = false
    @State private var rebuildTask: Task<Void, Never>?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(theme.surface)
                    InlineVideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    if isPreparing {
                        ProgressView().tint(theme.ink)
                    }
                }
                .frame(maxHeight: 420)
                .padding(.horizontal, 20)

                VStack(spacing: 8) {
                    Text("Müziği videoya göre kaydır")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                    Slider(
                        value: Binding(
                            get: { offset },
                            set: { newValue in
                                offset = newValue
                                scheduleRebuild()
                            }
                        ),
                        in: 0...max(0.01, maxOffset)
                    )
                    .tint(theme.accent)
                    .disabled(isPreparing || isExporting)

                    HStack {
                        Text(Self.format(offset))
                        Spacer()
                        Text(Self.format(musicDuration))
                    }
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
                }
                .padding(.horizontal, 24)

                Spacer()

                Button {
                    confirmAndExport()
                } label: {
                    if isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Kullan")
                            .font(Theme.headline(17))
                    }
                }
                .buttonStyle(.flapsePrimary)
                .disabled(isPreparing || isExporting)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .padding(.top, 12)
            .background(theme.canvas)
            .navigationTitle("Müzik Senkronu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                        .disabled(isExporting)
                }
            }
        }
        .task { await prepare() }
        .onDisappear {
            rebuildTask?.cancel()
            player.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
        }
    }

    private var maxOffset: Double { max(0, musicDuration - 3) }

    private func prepare() async {
        let audioAsset = AVURLAsset(url: soundtrackURL)
        let videoAsset = AVURLAsset(url: videoURL)
        musicDuration = (try? await audioAsset.load(.duration).seconds) ?? 0
        videoDuration = (try? await videoAsset.load(.duration).seconds) ?? 0
        offset = min(initialOffset, max(0, musicDuration - 3))
        await rebuildPreview()
        isPreparing = false
        player.play()
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
    }

    private func rebuildPreview() async {
        guard let composition = await Self.makeComposition(
            videoURL: videoURL,
            audioURL: soundtrackURL,
            startOffset: offset
        ) else { return }
        let wasPlaying = player.rate > 0
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        let item = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: item)
        let loopPlayer = player
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak loopPlayer] _ in
            Task { @MainActor in
                loopPlayer?.seek(to: .zero)
                loopPlayer?.play()
            }
        }
        if wasPlaying || !isPreparing {
            player.play()
        }
    }

    private func confirmAndExport() {
        isExporting = true
        Task {
            let result = try? await SoundtrackMuxer.mux(videoURL: videoURL, audioURL: soundtrackURL, startOffset: offset)
            isExporting = false
            guard let result else { return }
            onConfirm(result, offset)
            dismiss()
        }
    }

    /// Önizleme için: gerçek video karesi + seçilen noktadan başlayan müzik, diske
    /// yazmadan (`AVAssetExportSession` olmadan) doğrudan oynatılabilir bir kompozisyon.
    private static func makeComposition(videoURL: URL, audioURL: URL, startOffset: Double) async -> AVComposition? {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard
            let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
            let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first
        else { return nil }

        let composition = AVMutableComposition()
        guard
            let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let videoDuration = (try? await videoAsset.load(.duration)) ?? .zero
        try? compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

        let audioDuration = (try? await audioAsset.load(.duration)) ?? .zero
        guard audioDuration.seconds > 0 else { return composition }
        let clampedOffset = max(0, min(startOffset, max(0, audioDuration.seconds - 0.1)))
        var sourcePosition = CMTime(seconds: clampedOffset, preferredTimescale: audioDuration.timescale)
        var cursor = CMTime.zero
        while cursor < videoDuration {
            let remainingVideo = videoDuration - cursor
            let remainingSource = audioDuration - sourcePosition
            let chunk = min(remainingVideo, remainingSource)
            guard chunk > .zero else { break }
            try? compAudio.insertTimeRange(CMTimeRange(start: sourcePosition, duration: chunk), of: audioTrack, at: cursor)
            cursor = cursor + chunk
            sourcePosition = .zero
        }
        return composition
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
