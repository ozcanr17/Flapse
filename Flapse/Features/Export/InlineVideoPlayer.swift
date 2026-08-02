import AVKit
import SwiftUI

struct InlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// Bir dosya URL'ini oynatan, oynatıcısını KENDİSİ sahiplenen görünüm.
///
/// Oynatıcıyı `@State private var player: AVPlayer?` olarak tutup `.onAppear` içinde
/// kurmak güvenilir değildir: oynatıcı henüz `nil`ken sarmalayıcı görünüm boş kalır
/// ve boş bir görünüme bağlı `.onAppear` tetiklenmeyebilir — sonuç, hiç oynatıcı
/// oluşturulmadığı için tamamen siyah bir ekrandır. Oynatıcı burada `init` içinde
/// kurulduğundan görünüm hiçbir zaman boş olmaz.
struct AutoplayVideoPlayer: View {
    private let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        InlineVideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}
