import Foundation
import os

/// Çekim düğmesine basıştan kamera önizlemesinin belirmesine kadar geçen yolu
/// adım adım ölçer.
///
/// Cihazda bu aralık ~1.2-1.5 sn sürüyor ama kamera oturumunun kendisi ~20-70 ms'de
/// hazır oluyor; aradaki fark sunum/oluşturma tarafında. Buradaki işaretler o boşluğun
/// hangi adımda geçtiğini tahmine gerek kalmadan gösterir.
///
/// Okumak için: Xcode konsolunda `LAUNCHTRACE` ile filtrele, ya da
/// `log stream --predicate 'subsystem == "rozcan.Flapse" AND category == "camera"'`.
enum CameraLaunchTrace {

    // Yayınlanan derlemede iz yayılmaz; `cameraLog` da orada `OSLog.disabled`'a bağlı.
    #if DEBUG
    private static let signposter = OSSignposter(
        subsystem: "rozcan.Flapse",
        category: "camera.launch"
    )
    #else
    private static let signposter = OSSignposter(logHandle: OSLog.disabled)
    #endif

    nonisolated(unsafe) private static var startedAt: CFAbsoluteTime?
    nonisolated(unsafe) private static var lastAt: CFAbsoluteTime?
    nonisolated(unsafe) private static var intervalState: OSSignpostIntervalState?

    static func begin(_ source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        startedAt = now
        lastAt = now
        intervalState = signposter.beginInterval("camera-launch")
        cameraLog.notice("LAUNCHTRACE ── begin (\(source, privacy: .public))")
    }

    /// Bir adımı işaretler: başlangıçtan toplam süre ve bir önceki adımdan bu yana
    /// geçen süre birlikte yazılır — böylece maliyetin hangi adımda olduğu doğrudan görünür.
    static func mark(_ label: String) {
        guard let startedAt else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let total = (now - startedAt) * 1000
        let delta = (now - (lastAt ?? startedAt)) * 1000
        lastAt = now
        signposter.emitEvent("step", "\(label)")
        cameraLog.notice("LAUNCHTRACE \(label, privacy: .public): +\(delta, format: .fixed(precision: 1))ms (toplam \(total, format: .fixed(precision: 1))ms)")
    }

    static func end(_ label: String) {
        mark(label)
        if let intervalState {
            signposter.endInterval("camera-launch", intervalState)
        }
        intervalState = nil
        startedAt = nil
        lastAt = nil
    }
}
