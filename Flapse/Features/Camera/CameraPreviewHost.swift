import AVFoundation
import UIKit

/// Önizleme katmanını UYGULAMA ÖMRÜ boyunca tek sefer kurar.
///
/// Ölçüm: `AVCaptureVideoPreviewLayer.session` ataması ana thread'i bloke ediyor
/// (cihazda 700-1500 ms, simülatörde daha fazla). Katman `CameraPreview` içinde
/// kurulduğunda bu maliyet her kamera açılışında — üstelik SwiftUI görünümü birkaç
/// kez yeniden yarattığı için birden fazla kez — sunum yoluna biniyordu. Katmanı
/// burada bir kez kurup her açılışta yeniden kullanıyoruz.
@MainActor
final class CameraPreviewHost {

    static let shared = CameraPreviewHost()

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    private var cachedView: PreviewView?

    /// Uygulama açılışında bir kez çağrılır; pahalı atamayı kamera yolundan çıkarır.
    func warmUp() {
        _ = view
    }

    var view: PreviewView {
        if let cachedView { return cachedView }
        let created = PreviewView()
        created.videoPreviewLayer.videoGravity = .resizeAspectFill
        created.videoPreviewLayer.session = CameraService.shared.session
        cachedView = created
        return created
    }

    /// Ekrandaki dokunuş noktasını kameranın kendi koordinat sistemine çevirir.
    func devicePoint(for layerPoint: CGPoint) -> CGPoint {
        view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
    }

    func setMirrored(_ mirrored: Bool) {
        guard let connection = view.videoPreviewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
