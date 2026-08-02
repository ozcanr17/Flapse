import AVFoundation
import SwiftUI
import UIKit

/// Tam ekran düğmesi OLMAYAN sade oynatıcı.
///
/// `AVPlayerViewController` satır içi kullanıldığında bir büyütme düğmesi gösteriyor;
/// tam ekrana geçip çıkınca oynatma bozuluyor ve kare bir daha oynatılamıyordu.
/// Burada yalnızca `AVPlayerLayer` var: dokununca oynat/duraklat, başka kontrol yok.
struct SimpleVideoPlayer: View {

    let url: URL
    @State private var player: AVPlayer
    @State private var isPlaying = true

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        PlayerLayerView(player: player)
            .overlay {
                if !isPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.3), radius: 6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .onAppear { restart() }
            .onDisappear { player.pause() }
            // Klip bitince başa sarılır ve oynat simgesi belirir; aksi hâlde oynatıcı
            // sonda kalıyor ve dokunmak videoyu bir daha başlatmıyordu.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: AVPlayerItem.didPlayToEndTimeNotification,
                    object: player.currentItem
                )
            ) { _ in
                player.seek(to: .zero)
                isPlaying = false
            }
    }

    /// Dokunuş: oynuyorsa duraklat, duraklatılmışsa devam et, bittiyse baştan oynat.
    private func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            restart()
        }
    }

    private func restart() {
        if let item = player.currentItem, item.duration.isValid,
           player.currentTime() >= item.duration - CMTime(value: 1, timescale: 10) {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    private struct PlayerLayerView: UIViewRepresentable {
        let player: AVPlayer

        func makeUIView(context: Context) -> LayerView {
            let view = LayerView()
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspect
            return view
        }

        func updateUIView(_ uiView: LayerView, context: Context) {
            if uiView.playerLayer.player !== player {
                uiView.playerLayer.player = player
            }
        }

        final class LayerView: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        }
    }
}
