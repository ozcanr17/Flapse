import Foundation
import SwiftData
import AVFoundation
import UIKit
import os

/// Kamera ekranının mantığı. Donanımı (CameraServiceProtocol) ve kalıcılığı
/// (ProjectRepositoryProtocol) protokol olarak alır; bu sayede gerçek kamera olmadan,
/// sahte servislerle test edilebilir.
@MainActor
@Observable
final class CameraCaptureViewModel {

    enum State: Equatable {
        case starting
        case ready
        case capturing
        case recording
        case failed(String)
    }

    /// Kameranın o an ne kaydettiği. Proje sabitse (fotoğraf ya da video kategorisi)
    /// bu değer o projenin türüne kilitlenir ve değiştirilemez — kullanıcı farklı bir
    /// tür kaydedemez. Proje henüz belirlenmemişse (otomatik sıralama akışı) kullanıcı
    /// modlar arasında geçiş yapabilir.
    enum CaptureKind: Equatable {
        case photo
        case video
    }

    static let maxVideoDuration: TimeInterval = 15

    private(set) var state: State = .starting

    /// Hizalama referans noktası (0...1 normalize). Bir önceki çekimden başlar,
    /// kullanıcı önizlemeye dokununca güncellenir, çekimde Entry'ye kaydedilir.
    private(set) var referenceAnchor: NormalizedPoint

    private(set) var position: AVCaptureDevice.Position
    private(set) var isSwitching = false
    private(set) var zoomFactor: CGFloat = 1
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Cihazın gerçek optik zoom durakları; kamerada gösterilecek düğmeleri belirler.
    private(set) var zoomStops: [CGFloat] = [1]
    private(set) var flashMode: CameraFlashMode = .auto
    private(set) var aspectRatio: CameraAspectRatio = .resolved(
        from: UserDefaults.standard.string(forKey: CameraAspectRatio.storageKey) ?? ""
    )

    private let camera: CameraServiceProtocol
    private let repository: ProjectRepositoryProtocol
    private let project: Project?
    private let retakeEntry: Entry?
    private let classifier: SubjectClassifying
    private let location: LocationProviding
    private let onCaptured: ((Data) -> Void)?
    private let onVideoCaptured: ((URL, Double, Data?) -> Void)?

    private(set) var captureKind: CaptureKind

    init(
        camera: CameraServiceProtocol,
        repository: ProjectRepositoryProtocol,
        project: Project? = nil,
        retakeEntry: Entry? = nil,
        classifier: SubjectClassifying = SubjectClassifier(),
        location: LocationProviding? = nil,
        onCaptured: ((Data) -> Void)? = nil,
        onVideoCaptured: ((URL, Double, Data?) -> Void)? = nil
    ) {
        self.camera = camera
        self.repository = repository
        self.project = project
        self.retakeEntry = retakeEntry
        self.classifier = classifier
        self.location = location ?? LocationService()
        self.onCaptured = onCaptured
        self.onVideoCaptured = onVideoCaptured
        self.referenceAnchor = Self.initialAnchor(for: project)
        self.position = Self.initialPosition(for: project?.category ?? .other)
        self.captureKind = Self.initialCaptureKind(for: project)
    }

    /// Önizleme katmanının bağlanacağı oturum.
    var session: AVCaptureSession { camera.session }

    /// "Ghost" bindirmesi için referans fotoğraf: yeniden çekimde karenin kendisi,
    /// normal çekimde bir önceki (en yeni) çekim.
    var ghostImageData: Data? {
        retakeEntry?.imageData ?? project?.sortedEntries.last?.imageData
    }

    /// Bu proje çift modu (birlikte çekim) için mi? Kamerada bölme kılavuzunu belirler.
    var isCoupleMode: Bool { project?.isCoupleMode ?? false }

    /// Kameranın hangi arayüzle açılacağı. Proje içindeki çekimler o projenin
    /// türüyle uyumludur (tek bir iş yapar, ipucu metnine gerek yoktur); yalnızca
    /// ana ekrandan açılan çekim modülerdir (dokun → fotoğraf, basılı tut → video).
    enum CaptureMode {
        case photoOnly
        case videoOnly
        case modular
    }

    var captureMode: CaptureMode {
        guard let project else { return .modular }
        return project.category.isVideoMode ? .videoOnly : .photoOnly
    }

    var canRecordVideo: Bool { captureMode != .photoOnly }

    var canCapturePhoto: Bool { captureMode != .videoOnly }

    /// Kullanıcı önizlemeye dokununca referans noktasını oraya taşır.
    func setAnchor(_ point: NormalizedPoint) {
        referenceAnchor = point
    }

    func start() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        cameraLog.notice("VM.start: begin captureKind=\(String(describing: self.captureKind))")
        state = .starting
        do {
            // `videoCapable` oturum boyunca kalıcıdır (proje sabitse o türde; proje
            // yoksa anahtar açık olabileceğinden baştan video-capable kurulur — böylece
            // kullanıcı Video'ya geçince çıkışlar/preset yeniden kurulmaz). Mikrofon
            // burada HİÇ eklenmez — yalnızca kayıt fiilen başlarken eklenir
            // (`startVideoRecording`), böylece açılış da mod geçişi de anlık kalır.
            try await camera.start(
                position: position,
                videoCapable: Self.sessionVideoCapable(for: project),
                micEnabled: captureMode == .videoOnly
            )
            // Oturum çalışır çalışmaz hazırız: zoom yeteneklerini öğrenmek için bir
            // `sessionQueue` turu daha beklemek, kareler çoktan akarken spinner'ı
            // ekranda ve deklanşörü pasif tutuyordu.
            state = .ready
            cameraLog.notice("VM.start: camera.start=\((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms READY")
            await refreshZoom()
        } catch {
            state = .failed(message(for: error))
            cameraLog.notice("VM.start: FAILED after \((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms error=\(String(describing: error))")
        }
    }


    func stop() {
        camera.stop()
    }

    func flipCamera() async {
        guard state == .ready, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        do {
            try await camera.switchCamera(to: newPosition)
            position = newPosition
            await refreshZoom()
        } catch {
            state = .failed(message(for: error))
        }
    }

    func setZoomFactor(_ factor: CGFloat, smoothly: Bool = true) {
        guard state == .ready || state == .recording else { return }
        zoomFactor = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        camera.setZoomFactor(zoomFactor, smoothly: smoothly)
    }

    /// Fotoğrafı çeker; yeniden çekimde mevcut karenin fotoğrafını değiştirir,
    /// normal çekimde yeni bir Entry kaydeder.
    func capture() async -> Bool {
        guard state == .ready, !isSwitching else { return false }
        state = .capturing
        do {
            let raw = try await camera.capturePhoto()
            let ratio = aspectRatio
            let data = await Task.detached(priority: .userInitiated) {
                PhotoAspectCropper.crop(raw, to: ratio)
            }.value
            if let onCaptured {
                onCaptured(data)
            } else if let retakeEntry {
                try repository.replaceImage(for: retakeEntry, with: data)
            } else if let project {
                let signature = await classifier.signature(for: data)
                let entry = Entry(
                    imageData: data,
                    anchorX: referenceAnchor.x,
                    anchorY: referenceAnchor.y,
                    subjectKindRaw: signature.kind == .unknown ? nil : signature.kind.rawValue,
                    featurePrintData: signature.isEmpty ? nil : FeatureVector.data(from: signature.vector)
                )
                try finishEntry(entry, in: project)
            } else {
                state = .ready
                return false
            }
            state = .ready
            return true
        } catch {
            state = .failed(message(for: error))
            return false
        }
    }

    /// En/boy oranını 16:9 → 4:3 → 1:1 sırasıyla döndürür ve seçimi hatırlar.
    func cycleAspectRatio() {
        aspectRatio = aspectRatio.next
        UserDefaults.standard.set(aspectRatio.rawValue, forKey: CameraAspectRatio.storageKey)
        cameraLog.notice("ASPECT → \(self.aspectRatio.rawValue, privacy: .public)")
    }

    /// Flaşı sırayla Otomatik → Açık → Kapalı arasında döndürür.
    func cycleFlashMode() {
        flashMode = flashMode.next
        camera.setFlashMode(flashMode)
        if state == .recording {
            camera.setTorchEnabled(flashMode == .on)
        }
        cameraLog.notice("FLASH → \(self.flashMode.rawValue, privacy: .public)")
    }

    /// Önizlemede dokunulan noktaya odaklanır.
    func focus(at devicePoint: CGPoint) {
        guard state == .ready || state == .recording else { return }
        camera.focus(at: devicePoint)
    }

    /// Ana ekran kamerasındaki Fotoğraf/Video anahtarı. Oturuma dokunmaz — yalnızca
    /// yerel durumu değiştirir, bu yüzden anında tepki verir. Her dokunuş ve sonucu
    /// loglanır; anahtar yine takılırsa `MODESWITCH` ile filtreleyip görebiliriz.
    func setCaptureKind(_ kind: CaptureKind) {
        guard captureMode == .modular else {
            cameraLog.notice("MODESWITCH reddedildi: mod=\(String(describing: self.captureMode))")
            return
        }
        guard state != .recording else {
            cameraLog.notice("MODESWITCH reddedildi: kayıt sürüyor")
            return
        }
        let previous = captureKind
        captureKind = kind
        cameraLog.notice("MODESWITCH \(String(describing: previous)) → \(String(describing: kind)) (state=\(String(describing: self.state)))")
        // Ses girişini oturuma eklemek cihazda ~700 ms sürüyor. Kayıt tuşuna
        // basıldığında yapılırsa o an donma olarak hissediliyordu; Video moduna
        // geçildiği anda yapınca kullanıcı zaten kadraj kuruyor, maliyet görünmüyor.
        Task { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            try? await self.camera.setMicrophoneEnabled(kind == .video)
            cameraLog.notice("MICPREARM \(kind == .video ? "on" : "off", privacy: .public): \((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
        }
    }

    /// Parmak deklanşöre değdiği anda mikrofonu hazırlar. Çalışan bir oturuma ses
    /// girişi eklemek cihazda ~700 ms sürüyor; kayıt eşiği beklenirken başlatılınca
    /// bu sürenin bir kısmı kullanıcıya yansımadan geçer. Yalnızca modüler (ana ekran)
    /// çekimde gerekir — video projelerinde mikrofon zaten açılışta hazırlanır.
    func prepareMicrophoneForHold() async {
        guard captureMode == .modular, state == .ready else { return }
        try? await camera.setMicrophoneEnabled(true)
    }

    /// Basış kayda dönüşmediyse (kullanıcı fotoğraf çekti) mikrofonu geri kapatır.
    func releaseMicrophoneIfIdle() async {
        guard captureMode == .modular, state != .recording else { return }
        try? await camera.setMicrophoneEnabled(false)
    }

    /// Deklanşör basılı tutulunca çağrılır. Modu kendisi `.video`'ya alır — ayrı bir
    /// anahtar yok. Mikrofon da burada, kayıt gerçekten başlarken eklenir; böylece
    /// kamera açılışı ve normal fotoğraf çekimi hiçbir zaman mikrofon kurulumunu
    /// beklemez.
    func startVideoRecording() async {
        guard canRecordVideo, state == .ready, !isSwitching else { return }
        captureKind = .video
        state = .recording
        do {
            // Mikrofon modüler akışta Video moduna geçilirken zaten hazırlandı;
            // bu çağrı o durumda ucuz bir no-op (`updateAudioInput` durum aynıysa
            // hemen döner). Hazır değilse burada eklenir — ses asla kaçmaz.
            try await camera.setMicrophoneEnabled(true)
            camera.setTorchEnabled(flashMode == .on)
            try await camera.startRecording(maxDuration: Self.maxVideoDuration)
        } catch {
            captureKind = Self.initialCaptureKind(for: project)
            state = .failed(message(for: error))
        }
    }

    /// Video kaydını bitirir. `onVideoCaptured` doluysa (proje henüz belirlenmemiş,
    /// "otomatik sıralama" akışı) klip kalıcı depoya taşınmadan çağırana teslim edilir —
    /// proje seçimi/oluşturması tamamlanınca çağıran taşıma işlemini kendisi yapar.
    /// Aksi halde (bilinen proje) klip doğrudan `VideoEntryStorage`'a taşınıp Entry olarak eklenir.
    @discardableResult
    func finishVideoRecording() async -> Bool {
        guard state == .recording else { return false }
        do {
            let tempURL = try await camera.stopRecording()
            camera.setTorchEnabled(false)
            // Modüler akışta kullanıcı hâlâ Video modunda; mikrofonu kapatmak
            // sonraki kayıtta yine 700 ms'lik bekleme demek olurdu.
            if captureMode != .modular {
                try? await camera.setMicrophoneEnabled(false)
                captureKind = Self.initialCaptureKind(for: project)
            }

            if let onVideoCaptured {
                let asset = AVURLAsset(url: tempURL)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let posterData = await Self.posterData(for: tempURL)
                onVideoCaptured(tempURL, duration, posterData)
                state = .ready
                return true
            }

            guard let project else {
                state = .ready
                return false
            }

            let entryID = UUID()
            let destination = VideoEntryStorage.directory
                .appendingPathComponent(VideoEntryStorage.fileName(for: entryID))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let posterData = await Self.posterData(for: destination)

            // Video girdileri de fotoğraflarla aynı obje/kişi tanımasından geçer:
            // imza poster (ilk kare) üzerinden hesaplanır, böylece hizalama, proje
            // eşleştirme ve konu bazlı özellikler video kliplerde de çalışır.
            let signature: SubjectSignature
            if let posterData {
                signature = await classifier.signature(for: posterData)
            } else {
                signature = .empty
            }

            let entry = Entry(
                id: entryID,
                imageData: posterData,
                subjectKindRaw: signature.kind == .unknown ? nil : signature.kind.rawValue,
                featurePrintData: signature.isEmpty ? nil : FeatureVector.data(from: signature.vector),
                videoFileName: VideoEntryStorage.fileName(for: entryID),
                videoDuration: duration
            )
            try finishEntry(entry, in: project)
            state = .ready
            return true
        } catch {
            state = .failed(message(for: error))
            return false
        }
    }

    /// Poster (ilk kare) üretimi: tam `.zero` anı bazı kayıtlarda karesiz olabildiği
    /// için tolerans veriyor ve başarısız olursa biraz ileriden yeniden deniyor.
    /// Poster boş kalırsa ızgarada ve paylaşımda boş kare görünür.
    nonisolated static func posterData(for videoURL: URL) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        for seconds in [0.0, 0.1, 0.5] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
            }
        }
        return nil
    }

    /// Fotoğraf ve video çekimi arasında paylaşılan bitirme adımları: kaydet,
    /// konumu ekle, kilometre taşı bildirimini tetikle.
    private func finishEntry(_ entry: Entry, in project: Project) throws {
        try repository.addEntry(entry, to: project)
        captureLocation(for: entry)
        let live = project.sortedEntries.filter { !$0.isDeleted }
        if let message = ActivitySummary.milestone(
            count: live.count,
            streak: ActivitySummary.streak(capturedDates: live.map(\.capturedAt))
        ) {
            NotificationCenter.default.post(name: .flapseMilestone, object: message)
        }
    }

    private func captureLocation(for entry: Entry) {
        Task {
            guard let resolved = await location.currentLocation() else { return }
            entry.latitude = resolved.latitude
            entry.longitude = resolved.longitude
            entry.placeName = resolved.placeName
            try? repository.saveIfNeeded()
        }
    }

    private func refreshZoom() async {
        let capabilities = await camera.zoomCapabilities()
        zoomRange = capabilities.range
        zoomFactor = capabilities.factor
        if !capabilities.opticalStops.isEmpty { zoomStops = capabilities.opticalStops }
    }

    /// Oturumun video-capable kurulup kurulmayacağının TEK kaynağı. `prewarm()` ve
    /// `start()` bu değeri aynı şekilde hesaplamak ZORUNDA: aksi halde `start()`,
    /// çalışan bir oturumda tüm çıkışları söküp preset'i değiştirmek zorunda kalır —
    /// AVFoundation'daki en pahalı işlem — ve kamera görünür şekilde geç açılır.
    static func sessionVideoCapable(for project: Project?) -> Bool {
        guard let project else { return true }
        return project.category.isVideoMode
    }

    static func initialPosition(for category: ProjectCategory) -> AVCaptureDevice.Position {
        switch category {
        case .selfPortrait, .hairAndBeard: .front
        default: .back
        }
    }

    /// Proje sabitse doğrudan o türde açılır (kullanıcı farklı bir tür kaydetmesin);
    /// proje yoksa (otomatik sıralama) fotoğrafla başlar — mikrofon izni ve ek oturum
    /// yapılandırması yalnızca kullanıcı gerçekten Video moduna geçince istenir.
    private static func initialCaptureKind(for project: Project?) -> CaptureKind {
        guard let project else { return .photo }
        return project.category.isVideoMode ? .video : .photo
    }

    // Referans noktası: önceki çekimde tanımlıysa onu sürdür, yoksa ortadan başla.
    private static func initialAnchor(for project: Project?) -> NormalizedPoint {
        if let last = project?.sortedEntries.last, let x = last.anchorX, let y = last.anchorY {
            return NormalizedPoint(x: x, y: y)
        }
        return NormalizedPoint(x: 0.5, y: 0.5)
    }

    private func message(for error: Error) -> String {
        guard let cameraError = error as? CameraError else {
            return String(localized: "Beklenmeyen bir hata oluştu: \(error.localizedDescription)", bundle: .appLanguage)
        }
        switch cameraError {
        case .notAuthorized:        return String(localized: "Kamera izni verilmedi. Ayarlar’dan açabilirsin.", bundle: .appLanguage)
        case .configurationFailed:  return String(localized: "Kamera başlatılamadı.", bundle: .appLanguage)
        case .imageDataUnavailable: return String(localized: "Fotoğraf verisi alınamadı.", bundle: .appLanguage)
        case .captureInterrupted:   return String(localized: "Çekim yarıda kesildi. Tekrar dene.", bundle: .appLanguage)
        case .microphoneNotAuthorized: return String(localized: "Mikrofon izni verilmedi. Ayarlar’dan açabilirsin.", bundle: .appLanguage)
        case .recordingFailed:     return String(localized: "Video kaydedilemedi. Tekrar dene.", bundle: .appLanguage)
        }
    }
}
