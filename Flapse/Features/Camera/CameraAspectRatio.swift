import CoreGraphics
import Foundation
import UIKit

/// Kameranın çerçeve oranı. Kullanıcının son seçimi hatırlanır.
enum CameraAspectRatio: String, CaseIterable, Sendable {
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"
    case ratio1x1 = "1:1"

    static let storageKey = "camera.aspectRatio"

    /// Genişlik / yükseklik.
    var value: CGFloat {
        switch self {
        case .ratio16x9: 9.0 / 16.0
        case .ratio4x3:  3.0 / 4.0
        case .ratio1x1:  1
        }
    }

    var label: String { rawValue }

    var next: CameraAspectRatio {
        switch self {
        case .ratio16x9: .ratio4x3
        case .ratio4x3:  .ratio1x1
        case .ratio1x1:  .ratio16x9
        }
    }

    static func resolved(from stored: String) -> CameraAspectRatio {
        CameraAspectRatio(rawValue: stored) ?? .ratio16x9
    }
}

/// Çekilen fotoğrafı seçilen orana kırpar. Sensör 4:3 ürettiği için 16:9 ve 1:1
/// birer kırpmadır — önizlemede görülen çerçevenin aynısı kaydedilsin diye burada
/// da aynı oran uygulanır.
enum PhotoAspectCropper {

    static func crop(_ data: Data, to ratio: CameraAspectRatio) -> Data {
        guard ratio != .ratio4x3,
              let image = UIImage(data: data),
              let cgImage = image.cgImage
        else { return data }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // Görüntü dik çekilmiş olabilir; oranı görüntünün kendi yönüne göre uygula.
        let isPortrait = image.imageOrientation == .right || image.imageOrientation == .left
        let target = isPortrait ? 1 / ratio.value : ratio.value

        var cropWidth = width
        var cropHeight = height
        if width / height > target {
            cropWidth = height * target
        } else {
            cropHeight = width / target
        }
        let rect = CGRect(
            x: ((width - cropWidth) / 2).rounded(),
            y: ((height - cropHeight) / 2).rounded(),
            width: cropWidth.rounded(),
            height: cropHeight.rounded()
        )
        guard let cropped = cgImage.cropping(to: rect) else { return data }
        let result = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return ImageDownsampler.opaqueJPEGData(from: result, compressionQuality: 0.92) ?? data
    }
}
