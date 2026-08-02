import AVFoundation
import os

/// Kamera açılış/mod geçişi zamanlamasını görünür kılmak için: `log stream --predicate
/// 'subsystem == "rozcan.Flapse"'` ile canlı izlenebilir. Gerçek cihazda ya da
/// Instruments'ta darboğaz ararken kalıcı olarak burada kalması amaçlanır.
let cameraLog = Logger(subsystem: "rozcan.Flapse", category: "camera")

enum CameraFlashMode: String, CaseIterable, Sendable {
    case auto, on, off

    var icon: String {
        switch self {
        case .auto: "bolt.badge.a.fill"
        case .on:   "bolt.fill"
        case .off:  "bolt.slash.fill"
        }
    }

    var next: CameraFlashMode {
        switch self {
        case .auto: .on
        case .on:   .off
        case .off:  .auto
        }
    }
}

enum CameraError: Error {
    case notAuthorized
    case configurationFailed
    case imageDataUnavailable
    case captureInterrupted
    case microphoneNotAuthorized
    case recordingFailed
}

protocol CameraServiceProtocol: AnyObject {
    var session: AVCaptureSession { get }
    func start(position: AVCaptureDevice.Position, videoCapable: Bool, micEnabled: Bool) async throws
    func stop()
    func switchCamera(to position: AVCaptureDevice.Position) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func zoomCapabilities() async -> CameraZoomCapabilities
    func setZoomFactor(_ factor: CGFloat, smoothly: Bool)
    func focus(at devicePoint: CGPoint)
    func setFlashMode(_ mode: CameraFlashMode)
    func setTorchEnabled(_ enabled: Bool)
    func capturePhoto() async throws -> Data
    func startRecording(maxDuration: TimeInterval) async throws
    func stopRecording() async throws -> URL
}

struct CameraZoomCapabilities: Equatable, Sendable {
    let factor: CGFloat
    let range: ClosedRange<CGFloat>
    /// Cihazın GERÇEK optik durakları (ör. 0.5×, 1×, 3×). Her modelde farklıdır;
    /// sabit bir liste yerine donanımın kendi geçiş noktalarından türetilir.
    var opticalStops: [CGFloat] = []
}

final class CameraService: NSObject, CameraServiceProtocol, @unchecked Sendable {

    static let shared = CameraService()

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var currentInput: AVCaptureDeviceInput?
    private var lastConfiguredPosition: AVCaptureDevice.Position?
    private var flashMode: CameraFlashMode = .auto
    private var audioInput: AVCaptureDeviceInput?
    private var captureContinuation: CheckedContinuation<Data, Error>?
    private var recordingContinuation: CheckedContinuation<URL, Error>?

    /// Bu oturumda video çıkışı (ve `.high` preset) bir kez kurulunca KALICIDIR.
    /// Foto/Video anahtarı bu yüzden çıkışlara/preset'e asla dokunmaz — yalnızca
    /// `setMicrophoneEnabled` ile tek bir ses girişi eklenir/çıkarılır. `.photo`↔`.high`
    /// preset geçişi AVFoundation'da en pahalı yeniden yapılandırmalardan biridir;
    /// bunu mod başına değil, oturum başına en fazla bir kez ödüyoruz.
    private var isVideoCapable = false

    func prewarm(position: AVCaptureDevice.Position = .back, videoCapable: Bool = false, micEnabled: Bool = false) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            cameraLog.notice("prewarm: skipped, not authorized")
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("prewarm: dispatch to sessionQueue")
        sessionQueue.async {
            let tQueue = CFAbsoluteTimeGetCurrent()
            cameraLog.notice("prewarm: on sessionQueue after \((tQueue - t0) * 1000, format: .fixed(precision: 1))ms")
            try? self.configure(position: position, videoCapable: videoCapable, micEnabled: micEnabled)
            let tConfigured = CFAbsoluteTimeGetCurrent()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let tRunning = CFAbsoluteTimeGetCurrent()
            cameraLog.notice("prewarm: configure=\((tConfigured - tQueue) * 1000, format: .fixed(precision: 1))ms startRunning=\((tRunning - tConfigured) * 1000, format: .fixed(precision: 1))ms total=\((tRunning - t0) * 1000, format: .fixed(precision: 1))ms")
        }
    }

    func start(position: AVCaptureDevice.Position, videoCapable: Bool, micEnabled: Bool) async throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("start: begin videoCapable=\(videoCapable) micEnabled=\(micEnabled)")
        guard await Self.isAuthorized() else {
            cameraLog.notice("start: not authorized after \((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
            throw CameraError.notAuthorized
        }
        let tVideoAuth = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("start: video authorized after \((tVideoAuth - t0) * 1000, format: .fixed(precision: 1))ms")
        if micEnabled {
            guard await Self.isMicrophoneAuthorized() else {
                throw CameraError.microphoneNotAuthorized
            }
        }
        let tMicAuth = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("start: mic-auth-check after \((tMicAuth - tVideoAuth) * 1000, format: .fixed(precision: 1))ms")
        do {
            try await onSessionQueue {
                let tQueue = CFAbsoluteTimeGetCurrent()
                cameraLog.notice("start: on sessionQueue after \((tQueue - tMicAuth) * 1000, format: .fixed(precision: 1))ms")
                try self.configure(position: position, videoCapable: videoCapable, micEnabled: micEnabled)
                let tConfigured = CFAbsoluteTimeGetCurrent()
                if !self.session.isRunning { self.session.startRunning() }
                let tRunning = CFAbsoluteTimeGetCurrent()
                cameraLog.notice("start: configure=\((tConfigured - tQueue) * 1000, format: .fixed(precision: 1))ms startRunning=\((tRunning - tConfigured) * 1000, format: .fixed(precision: 1))ms")
            }
        } catch {
            cameraLog.notice("start: onSessionQueue threw \(String(describing: error))")
            throw error
        }
        cameraLog.notice("start: TOTAL=\((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func switchCamera(to position: AVCaptureDevice.Position) async throws {
        try await onSessionQueue {
            try self.configure(position: position, videoCapable: self.isVideoCapable, micEnabled: self.audioInput != nil)
        }
    }

    /// Foto/Video anahtarının tek dokunduğu yer: çıkışlar ve preset olduğu gibi kalır,
    /// yalnızca mikrofon girişi eklenir/çıkarılır. Bu yüzden mod geçişi hızlıdır.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("setMicrophoneEnabled(\(enabled)): begin")
        if enabled {
            guard await Self.isMicrophoneAuthorized() else { throw CameraError.microphoneNotAuthorized }
        }
        let tAuth = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("setMicrophoneEnabled: mic-auth-check=\((tAuth - t0) * 1000, format: .fixed(precision: 1))ms")
        try await onSessionQueue {
            let tQueue = CFAbsoluteTimeGetCurrent()
            cameraLog.notice("setMicrophoneEnabled: on sessionQueue after \((tQueue - tAuth) * 1000, format: .fixed(precision: 1))ms")
            try self.updateAudioInput(enabled: enabled)
            cameraLog.notice("setMicrophoneEnabled: updateAudioInput=\((CFAbsoluteTimeGetCurrent() - tQueue) * 1000, format: .fixed(precision: 1))ms")
        }
        cameraLog.notice("setMicrophoneEnabled: TOTAL=\((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
    }

    func zoomCapabilities() async -> CameraZoomCapabilities {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard let device = self.currentInput?.device else {
                    continuation.resume(returning: CameraZoomCapabilities(factor: 1, range: 1...1))
                    return
                }
                let multiplier = self.zoomDisplayMultiplier(for: device)
                let lower = device.minAvailableVideoZoomFactor * multiplier
                let upper = max(lower, min(device.maxAvailableVideoZoomFactor * multiplier, 10))
                continuation.resume(returning: CameraZoomCapabilities(
                    factor: min(max(device.videoZoomFactor * multiplier, lower), upper),
                    range: lower...upper,
                    opticalStops: self.opticalStops(for: device, multiplier: multiplier, in: lower...upper)
                ))
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat, smoothly: Bool) {
        sessionQueue.async {
            guard let device = self.currentInput?.device else { return }
            let multiplier = self.zoomDisplayMultiplier(for: device)
            let rawFactor = factor / max(multiplier, 0.01)
            let clamped = min(max(rawFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                if smoothly {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 4)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        sessionQueue.async { self.flashMode = mode }
    }

    /// Video kaydında flaş, sürekli ışık (torch) olarak çalışır — fotoğraftaki tek
    /// seferlik patlama video için anlamsızdır.
    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.currentInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Kullanıcının önizlemede dokunduğu noktaya odaklanır ve pozlamayı oraya göre
    /// ayarlar. Nokta, önizleme katmanı tarafından cihaz koordinatlarına çevrilmiş
    /// olmalıdır (0...1 aralığı).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                cameraLog.notice("focus: lockForConfiguration failed")
            }
        }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.sessionQueue.async {
                if let pending = self.captureContinuation {
                    self.captureContinuation = nil
                    pending.resume(throwing: CameraError.captureInterrupted)
                }
                if let connection = self.photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = self.currentInput?.device.position == .front
                }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                let desired: AVCaptureDevice.FlashMode = switch self.flashMode {
                case .auto: .auto
                case .on:   .on
                case .off:  .off
                }
                if self.photoOutput.supportedFlashModes.contains(desired) {
                    settings.flashMode = desired
                }
                self.captureContinuation = continuation
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func startRecording(maxDuration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.sessionQueue.async {
                guard self.session.outputs.contains(self.movieOutput) else {
                    continuation.resume(throwing: CameraError.configurationFailed)
                    return
                }
                guard !self.movieOutput.isRecording else {
                    continuation.resume(throwing: CameraError.captureInterrupted)
                    return
                }
                if let connection = self.movieOutput.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = self.currentInput?.device.position == .front
                }
                self.movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("flapse-clip-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
                self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
                continuation.resume()
            }
        }
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    continuation.resume(throwing: CameraError.recordingFailed)
                    return
                }
                self.recordingContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    private func onSessionQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.sessionQueue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func isAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default:             return false
        }
    }

    private static func isMicrophoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    /// Çıkışları ve preset'i yalnızca gerçekten gerekince (ilk kurulum, ya da fotoğraf-
    /// only bir oturumun video-capable'a yükseltilmesi) yeniden kurar; pozisyon
    /// değişimi yalnızca kamera girişini değiştirir. Mikrofon ayrı, ucuz bir adımdır.
    private func configure(position: AVCaptureDevice.Position, videoCapable: Bool, micEnabled: Bool) throws {
        // `currentInput` donanım yoksa (ör. Simulator) hep nil kalır; bu yüzden pozisyon
        // değişimini `currentInput`'a değil, en son DENENEN pozisyona göre belirliyoruz.
        // Aksi halde her `start()` çağrısı, `prewarm()`'ın zaten denediği (ve donanım
        // yoksa hep başarısız olacak) pahalı beginConfiguration/commitConfiguration
        // döngüsünü ÇALIŞAN bir session üzerinde tekrar tekrar tetikler — bu da gerçek
        // cihazda saniyelerce sürebilen görünür bir "kamera donuyor" gecikmesine yol açar.
        let positionChanged = lastConfiguredPosition != position
        let needsInitialSetup = session.outputs.isEmpty
        // Çift yönlü: video-capable'a yükseltmek kadar, video projesinden sonra
        // fotoğraf projesine dönerken `.photo` preset'ine GERİ DÖNMEK de gerekir —
        // aksi halde tek bir video çekiminden sonra oturum kalıcı olarak `.high`'ta
        // kalır ve sonraki tüm fotoğraflar video kalitesinde çekilir.
        let needsOutputChange = videoCapable != isVideoCapable
        cameraLog.notice("configure: instance=\(ObjectIdentifier(self).debugDescription) positionChanged=\(positionChanged) (lastConfigured=\(String(describing: self.lastConfiguredPosition?.rawValue)) requested=\(position.rawValue)) needsInitialSetup=\(needsInitialSetup) needsOutputChange=\(needsOutputChange) sessionRunning=\(self.session.isRunning)")

        if needsInitialSetup || needsOutputChange || positionChanged {
            let tBegin = CFAbsoluteTimeGetCurrent()
            session.beginConfiguration()

            if needsInitialSetup || needsOutputChange {
                if !needsInitialSetup {
                    for output in session.outputs { session.removeOutput(output) }
                }
                session.sessionPreset = videoCapable ? .high : .photo
                if session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                    photoOutput.maxPhotoQualityPrioritization = .balanced
                }
                if videoCapable, session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                }
                isVideoCapable = videoCapable
            }
            let tOutputs = CFAbsoluteTimeGetCurrent()

            if positionChanged {
                if let currentInput {
                    session.removeInput(currentInput)
                    self.currentInput = nil
                }
                let camera = preferredCamera(position: position)
                cameraLog.notice("configure: preferredCamera=\(String(describing: camera)) canAddInput-check next")
                if let camera,
                   let input = try? AVCaptureDeviceInput(device: camera),
                   session.canAddInput(input) {
                    session.addInput(input)
                    currentInput = input
                    cameraLog.notice("configure: input added successfully, self.currentInput now set=\(self.currentInput != nil) instance=\(ObjectIdentifier(self).debugDescription)")
                } else {
                    cameraLog.notice("configure: FAILED to add input (camera=\(camera != nil))")
                }
                lastConfiguredPosition = position
            }
            let tInput = CFAbsoluteTimeGetCurrent()

            session.commitConfiguration()
            let tCommit = CFAbsoluteTimeGetCurrent()
            cameraLog.notice("configure: outputs=\((tOutputs - tBegin) * 1000, format: .fixed(precision: 1))ms input=\((tInput - tOutputs) * 1000, format: .fixed(precision: 1))ms commit=\((tCommit - tInput) * 1000, format: .fixed(precision: 1))ms TOTAL=\((tCommit - tBegin) * 1000, format: .fixed(precision: 1))ms")
        } else {
            cameraLog.notice("configure: fast path, no reconfiguration needed")
        }

        // `lastConfiguredPosition` yukarıda güncellendiği için, donanımın gerçekten
        // eklenip eklenmediğini fast path dahil HER çağrıda burada doğruluyoruz —
        // böylece başarısızlık durumu (ör. Simulator'da kamera yok) pahalı bir
        // yeniden deneme yapılmadan da doğru şekilde raporlanmaya devam eder.
        guard currentInput != nil else {
            throw CameraError.configurationFailed
        }

        try updateAudioInput(enabled: micEnabled)
    }

    private func updateAudioInput(enabled: Bool) throws {
        guard isVideoCapable, enabled != (audioInput != nil) else {
            cameraLog.notice("updateAudioInput(\(enabled)): no-op")
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            cameraLog.notice("updateAudioInput(\(enabled)): \((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
        }
        if enabled {
            guard let micDevice = AVCaptureDevice.default(for: .audio),
                  let micInput = try? AVCaptureDeviceInput(device: micDevice),
                  session.canAddInput(micInput) else { return }
            session.addInput(micInput)
            audioInput = micInput
        } else if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
    }

    private func preferredCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Fiziksel objektiflerin devreye girdiği zoom değerleri. `virtualDeviceSwitchOverVideoZoomFactors`
    /// çoklu kamera sistemlerinde hangi oranda hangi objektife geçildiğini söyler;
    /// en geniş objektifin tabanıyla birleştirince cihazın gerçek optik durakları çıkar.
    private func opticalStops(
        for device: AVCaptureDevice,
        multiplier: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> [CGFloat] {
        var stops: [CGFloat] = [device.minAvailableVideoZoomFactor * multiplier]
        for value in device.virtualDeviceSwitchOverVideoZoomFactors {
            stops.append(CGFloat(truncating: value) * multiplier)
        }
        // Apple'ın Kamera uygulaması yalnızca objektif geçişlerini değil, ana sensörün
        // kırpılmasıyla elde edilen "optik kalitede" araları da gösterir (ör. 4× tele
        // varken 8×, 1× ana kamera varken 2×). Her durağın iki katını da aday yapıyoruz;
        // 17 Pro Max'te bu 0.5× / 1× / 2× / 4× / 8× verir, çift kameralı bir cihazda
        // 0.5× / 1× / 2× — yani her modelde kendi donanımına oturur.
        let doubled = stops.map { $0 * 2 }
        var unique: [CGFloat] = []
        for stop in (stops + doubled).sorted() where range.contains(stop) {
            if !unique.contains(where: { abs($0 - stop) < 0.05 }) { unique.append(stop) }
        }
        // Tek kameralı cihazlarda geçiş noktası yoktur; en azından 1× gösterilsin.
        if unique.isEmpty, range.contains(1) { unique = [1] }
        return unique
    }

    private func zoomDisplayMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return device.displayVideoZoomFactorMultiplier
        }
        return 1
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        sessionQueue.async {
            guard let continuation = self.captureContinuation else { return }
            self.captureContinuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: CameraError.imageDataUnavailable)
            }
        }
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            guard let continuation = self.recordingContinuation else { return }
            self.recordingContinuation = nil
            if let error, (error as NSError).code != -11818 {
                // -11818: maxRecordedDuration'a ulaşınca AVFoundation'ın kendi
                // durdurması da "error" olarak gelir; bu durumda dosya geçerlidir.
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: outputFileURL)
            }
        }
    }
}
