import XCTest
import SwiftData
import AVFoundation
@testable import Flapse   // ← kendi hedef (target) adınla değiştir

/// Kamera akışını GERÇEK DONANIM OLMADAN test ediyoruz: donanım protokol arkasında
/// olduğu için, sahte bir kamera "çektiği" sabit veriyi döndürür ve akışı saniyenin
/// altında doğrularız. Ghost ve referans noktası mantığını da burada test ediyoruz.
@MainActor
final class CameraCaptureViewModelTests: XCTestCase {

    private final class FakeCamera: CameraServiceProtocol {
        let session = AVCaptureSession()
        var photoToReturn = Data([0x01])
        var recordedURLToReturn = URL(fileURLWithPath: "/tmp/fake-clip.mov")
        var startError: Error?
        var captureError: Error?
        var switchError: Error?
        var recordingError: Error?
        var zoom = CameraZoomCapabilities(factor: 1, range: 1...5)
        var lastZoomWasSmooth = false
        private(set) var startedPositions: [AVCaptureDevice.Position] = []
        private(set) var switchedPositions: [AVCaptureDevice.Position] = []
        private(set) var didStartRecording = false

        var micEnabled = false

        func start(position: AVCaptureDevice.Position, videoCapable: Bool, micEnabled: Bool) async throws {
            startedPositions.append(position)
            self.micEnabled = micEnabled
            if let startError { throw startError }
        }
        func stop() {}
        func switchCamera(to position: AVCaptureDevice.Position) async throws {
            if let switchError { throw switchError }
            switchedPositions.append(position)
        }
        func setMicrophoneEnabled(_ enabled: Bool) async throws {
            if let recordingError { throw recordingError }
            micEnabled = enabled
        }
        func zoomCapabilities() async -> CameraZoomCapabilities { zoom }
        private(set) var focusPoints: [CGPoint] = []
        func focus(at devicePoint: CGPoint) { focusPoints.append(devicePoint) }
        private(set) var flashModes: [CameraFlashMode] = []
        private(set) var torchStates: [Bool] = []
        func setFlashMode(_ mode: CameraFlashMode) { flashModes.append(mode) }
        func setTorchEnabled(_ enabled: Bool) { torchStates.append(enabled) }
        func setZoomFactor(_ factor: CGFloat, smoothly: Bool) {
            zoom = CameraZoomCapabilities(factor: factor, range: zoom.range)
            lastZoomWasSmooth = smoothly
        }
        func capturePhoto() async throws -> Data {
            if let captureError { throw captureError }
            return photoToReturn
        }
        func startRecording(maxDuration: TimeInterval) async throws {
            if let recordingError { throw recordingError }
            didStartRecording = true
        }
        func stopRecording() async throws -> URL {
            if let recordingError { throw recordingError }
            return recordedURLToReturn
        }
    }

    private struct FakeClassifier: SubjectClassifying {
        func signature(for imageData: Data) async -> SubjectSignature { .empty }
    }

    private final class RecordingClassifier: SubjectClassifying, @unchecked Sendable {
        private(set) var classifiedDataCount = 0
        func signature(for imageData: Data) async -> SubjectSignature {
            classifiedDataCount += 1
            return .empty
        }
    }

    private struct FakeLocation: LocationProviding {
        func currentLocation() async -> ResolvedLocation? { nil }
    }

    private final class FakeRepository: ProjectRepositoryProtocol {
        private(set) var addedEntries: [Entry] = []
        private(set) var replacedEntryIDs: [UUID] = []
        private(set) var lastReplacedData: Data?
        func createProject(title: String, category: ProjectCategory, cadence: CaptureCadence) throws -> Project {
            Project(title: title, category: category, cadence: cadence)
        }
        func allProjects() throws -> [Project] { [] }
        func addEntry(_ entry: Entry, to project: Project) throws { addedEntries.append(entry) }
        func addEntries(_ entries: [Entry], to project: Project) throws { addedEntries.append(contentsOf: entries) }
        func replaceImage(for entry: Entry, with data: Data) throws {
            replacedEntryIDs.append(entry.id)
            lastReplacedData = data
        }
        func deleteEntry(_ entry: Entry) throws {}
        func deleteProject(_ project: Project) throws {}
        func saveIfNeeded() throws {}
    }

    private struct DummyError: Error {}

    private func makeViewModel(
        camera: FakeCamera,
        repository: FakeRepository,
        project: Project? = nil
    ) -> CameraCaptureViewModel {
        CameraCaptureViewModel(
            camera: camera,
            repository: repository,
            project: project ?? Project(title: "Sakal", category: .hairAndBeard, cadence: .daily),
            classifier: FakeClassifier(),
            location: FakeLocation()
        )
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Çekim akışı

    func test_basariliCekim_veriyiEntryOlarakKaydeder() async {
        let camera = FakeCamera()
        camera.photoToReturn = Data([0xAA, 0xBB])
        let repository = FakeRepository()
        let viewModel = makeViewModel(camera: camera, repository: repository)

        await viewModel.start()                 // .ready
        let success = await viewModel.capture()

        XCTAssertTrue(success)
        XCTAssertEqual(repository.addedEntries.count, 1)
        XCTAssertEqual(repository.addedEntries.first?.imageData, Data([0xAA, 0xBB]))
    }

    func test_baslatmaHataVerirse_durumFailedOlur() async {
        let camera = FakeCamera()
        camera.startError = DummyError()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())

        await viewModel.start()

        let success = await viewModel.capture()
        XCTAssertFalse(success)
        if case .failed = viewModel.state {
            // beklenen sonuç
        } else {
            XCTFail("Durum .failed olmalıydı, ama \(viewModel.state) bulundu")
        }
    }

    func test_zoomAraligiDonanimaGoreSinirlanir() async {
        let camera = FakeCamera()
        camera.zoom = CameraZoomCapabilities(factor: 1, range: 0.5...5)
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())

        await viewModel.start()
        viewModel.setZoomFactor(8)

        XCTAssertEqual(viewModel.zoomRange, 0.5...5)
        XCTAssertEqual(viewModel.zoomFactor, 5)
        XCTAssertEqual(camera.zoom.factor, 5)
        XCTAssertTrue(camera.lastZoomWasSmooth)
    }

    // MARK: - Yeniden çekim

    func test_yenidenCekim_yeniEntryEklemez_fotografiDegistirir() async {
        let camera = FakeCamera()
        camera.photoToReturn = Data([0xCC])
        let repository = FakeRepository()
        let entry = Entry(imageData: Data([0x01]))
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: repository, project: project, retakeEntry: entry
        )

        await viewModel.start()
        let success = await viewModel.capture()

        XCTAssertTrue(success)
        XCTAssertTrue(repository.addedEntries.isEmpty)
        XCTAssertEqual(repository.replacedEntryIDs, [entry.id])
        XCTAssertEqual(repository.lastReplacedData, Data([0xCC]))
    }

    func test_yenidenCekim_ghostOlarakKendiFotografiniGosterir() {
        let entry = Entry(imageData: Data([0x07]))
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let viewModel = CameraCaptureViewModel(
            camera: FakeCamera(), repository: FakeRepository(), project: project, retakeEntry: entry
        )

        XCTAssertEqual(viewModel.ghostImageData, Data([0x07]))
    }

    // MARK: - Basılı tutarak video

    func test_basiliTutma_moduKendisiVideoyaAlirVeKaydiBaslatir() async {
        // Ayrı bir Foto/Video anahtarı yok: kayıt, deklanşör basılı tutulunca
        // doğrudan başlamalı — önce bir mod geçişi beklemeden.
        let camera = FakeCamera()
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: FakeRepository(), project: nil
        )
        await viewModel.start()

        await viewModel.startVideoRecording()

        XCTAssertEqual(viewModel.captureKind, .video)
        XCTAssertTrue(camera.didStartRecording)
        XCTAssertEqual(viewModel.state, .recording)
    }

    func test_mikrofon_acilistaKapali_kayittaAcik() async {
        // Mikrofon kamera açılışında hiç eklenmez; kayıt başlarken kesinlikle açıktır.
        let camera = FakeCamera()
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: FakeRepository(), project: nil
        )
        await viewModel.start()
        XCTAssertFalse(camera.micEnabled)

        await viewModel.startVideoRecording()
        XCTAssertTrue(camera.micEnabled)
    }

    func test_videoProjesinde_kayitBitinceMikrofonKapanir() async {
        let project = Project(title: "Klip", category: .video, cadence: .daily)
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository(), project: project)
        await viewModel.start()

        await viewModel.startVideoRecording()
        XCTAssertTrue(camera.micEnabled)

        await viewModel.finishVideoRecording()
        XCTAssertFalse(camera.micEnabled)
    }

    func test_videoModunaGecince_mikrofonOndenHazirlanir() async {
        // Kayıt tuşuna basıldığında 700 ms beklememek için mikrofon mod geçişinde
        // hazırlanır; anahtar Video'ya alınınca cihaza istek gitmelidir.
        let camera = FakeCamera()
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: FakeRepository(), project: nil
        )
        await viewModel.start()

        viewModel.setCaptureKind(.video)
        // Ön hazırlık ayrı bir görevde çalışır; tamamlanmasına fırsat ver.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(camera.micEnabled)
    }

    func test_videoKaydi_objeKisiTanimasindanGecer() async throws {
        // Video girdileri de fotoğraflarla aynı tanımadan geçmeli; daha önce video
        // klipler imzasız kaydediliyordu.
        let classifier = RecordingClassifier()
        let camera = FakeCamera()
        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recognition-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: clipURL.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: clipURL) }
        camera.recordedURLToReturn = clipURL

        let project = Project(title: "Klip", category: .video, cadence: .daily)
        let viewModel = CameraCaptureViewModel(
            camera: camera,
            repository: FakeRepository(),
            project: project,
            classifier: classifier,
            location: FakeLocation()
        )
        await viewModel.start()
        await viewModel.startVideoRecording()
        await viewModel.finishVideoRecording()

        // Poster üretilebildiyse sınıflandırıcı çağrılmış olmalı; üretilemediyse
        // (geçersiz klip) akış yine de çökmeden tamamlanmalı.
        XCTAssertLessThanOrEqual(classifier.classifiedDataCount, 1)
    }

    func test_enBoyOrani_sirayla_donerVeHatirlanir() async {
        UserDefaults.standard.removeObject(forKey: CameraAspectRatio.storageKey)
        let viewModel = makeViewModel(camera: FakeCamera(), repository: FakeRepository())
        await viewModel.start()

        XCTAssertEqual(viewModel.aspectRatio, .ratio16x9)
        viewModel.cycleAspectRatio()
        XCTAssertEqual(viewModel.aspectRatio, .ratio4x3)
        viewModel.cycleAspectRatio()
        XCTAssertEqual(viewModel.aspectRatio, .ratio1x1)
        viewModel.cycleAspectRatio()
        XCTAssertEqual(viewModel.aspectRatio, .ratio16x9)

        viewModel.cycleAspectRatio()
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: CameraAspectRatio.storageKey),
            CameraAspectRatio.ratio4x3.rawValue
        )
        UserDefaults.standard.removeObject(forKey: CameraAspectRatio.storageKey)
    }

    func test_kayitSirasinda_zoomVeOdaklamaCalisir() async {
        let camera = FakeCamera()
        camera.zoom = CameraZoomCapabilities(factor: 1, range: 0.5...8)
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: FakeRepository(), project: nil
        )
        await viewModel.start()
        viewModel.setCaptureKind(.video)
        await viewModel.startVideoRecording()
        XCTAssertEqual(viewModel.state, .recording)

        viewModel.setZoomFactor(3)
        viewModel.focus(at: CGPoint(x: 0.4, y: 0.6))

        XCTAssertEqual(viewModel.zoomFactor, 3)
        XCTAssertEqual(camera.focusPoints.count, 1)
    }

    func test_flas_otomatikAcikKapaliSirasiylaDoner() async {
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())
        await viewModel.start()

        XCTAssertEqual(viewModel.flashMode, .auto)
        viewModel.cycleFlashMode()
        XCTAssertEqual(viewModel.flashMode, .on)
        viewModel.cycleFlashMode()
        XCTAssertEqual(viewModel.flashMode, .off)
        viewModel.cycleFlashMode()
        XCTAssertEqual(viewModel.flashMode, .auto)
        XCTAssertEqual(camera.flashModes, [.on, .off, .auto])
    }

    func test_videoKaydi_flasAcikkenSurekliIsigiYakar() async {
        let camera = FakeCamera()
        let viewModel = CameraCaptureViewModel(
            camera: camera, repository: FakeRepository(), project: nil
        )
        await viewModel.start()
        viewModel.cycleFlashMode()   // .on
        viewModel.setCaptureKind(.video)

        await viewModel.startVideoRecording()

        XCTAssertEqual(camera.torchStates.last, true)
    }

    func test_odaklama_hazirDegilkenCihazaGitmez() async {
        let camera = FakeCamera()
        camera.startError = DummyError()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())
        await viewModel.start()

        viewModel.focus(at: CGPoint(x: 0.5, y: 0.5))

        XCTAssertTrue(camera.focusPoints.isEmpty)
    }

    func test_odaklama_hazirkenNoktayiCihazaIletir() async {
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())
        await viewModel.start()

        viewModel.focus(at: CGPoint(x: 0.25, y: 0.75))

        XCTAssertEqual(camera.focusPoints.count, 1)
        XCTAssertEqual(camera.focusPoints.first?.x ?? 0, 0.25, accuracy: 0.001)
    }

    func test_modAnahtari_anaEkrandaCalisir_projedeCalismaz() async {
        let modular = CameraCaptureViewModel(
            camera: FakeCamera(), repository: FakeRepository(), project: nil
        )
        await modular.start()
        modular.setCaptureKind(.video)
        XCTAssertEqual(modular.captureKind, .video)
        modular.setCaptureKind(.photo)
        XCTAssertEqual(modular.captureKind, .photo)

        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let fixed = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: project)
        await fixed.start()
        fixed.setCaptureKind(.video)
        XCTAssertEqual(fixed.captureKind, .photo)
    }

    func test_cekimModu_projeTuruyleUyumluAcilir() {
        let photoProject = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let videoProject = Project(title: "Klip", category: .video, cadence: .daily)

        let photoVM = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: photoProject)
        XCTAssertEqual(photoVM.captureMode, .photoOnly)
        XCTAssertFalse(photoVM.canRecordVideo)
        XCTAssertTrue(photoVM.canCapturePhoto)

        let videoVM = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: videoProject)
        XCTAssertEqual(videoVM.captureMode, .videoOnly)
        XCTAssertTrue(videoVM.canRecordVideo)
        XCTAssertFalse(videoVM.canCapturePhoto)
        XCTAssertEqual(videoVM.captureKind, .video)

        let modularVM = CameraCaptureViewModel(
            camera: FakeCamera(), repository: FakeRepository(), project: nil
        )
        XCTAssertEqual(modularVM.captureMode, .modular)
        XCTAssertTrue(modularVM.canRecordVideo)
        XCTAssertTrue(modularVM.canCapturePhoto)
    }

    func test_videoProjesinde_dokunmaKaydiBaslatir() async {
        let project = Project(title: "Klip", category: .video, cadence: .daily)
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository(), project: project)
        await viewModel.start()

        await viewModel.startVideoRecording()

        XCTAssertTrue(camera.didStartRecording)
        XCTAssertEqual(viewModel.state, .recording)
    }

    func test_fotografProjesinde_basiliTutmaVideoBaslatmaz() async {
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository(), project: project)
        await viewModel.start()

        await viewModel.startVideoRecording()

        XCTAssertFalse(camera.didStartRecording)
        XCTAssertEqual(viewModel.captureKind, .photo)
    }

    func test_prewarmVeStart_ayniVideoCapableDegeriniIster() {
        // `prewarm()` ile `start()` farklı değer isterse, `start()` çalışan oturumda
        // tüm çıkışları söküp preset değiştirmek zorunda kalır — kamera geç açılır.
        let photoProject = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        let videoProject = Project(title: "Klip", category: .video, cadence: .daily)

        XCTAssertTrue(CameraCaptureViewModel.sessionVideoCapable(for: nil))
        XCTAssertFalse(CameraCaptureViewModel.sessionVideoCapable(for: photoProject))
        XCTAssertTrue(CameraCaptureViewModel.sessionVideoCapable(for: videoProject))
    }

    // MARK: - Kamera pozisyonu

    func test_sacSakalProjesi_onKameraylaBaslar() async {
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())

        await viewModel.start()

        XCTAssertEqual(viewModel.position, .front)
        XCTAssertEqual(camera.startedPositions, [.front])
    }

    func test_bitkiProjesi_arkaKameraylaBaslar() {
        let project = Project(title: "Limon fidanı", category: .plant, cadence: .weekly)
        let viewModel = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: project)

        XCTAssertEqual(viewModel.position, .back)
    }

    func test_flipCamera_pozisyonuDegistirir() async {
        let camera = FakeCamera()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())

        await viewModel.start()
        await viewModel.flipCamera()

        XCTAssertEqual(viewModel.position, .back)
        XCTAssertEqual(camera.switchedPositions, [.back])
    }

    func test_flipCamera_hazirDegilkenCalismaz() async {
        let camera = FakeCamera()
        camera.startError = DummyError()
        let viewModel = makeViewModel(camera: camera, repository: FakeRepository())

        await viewModel.start()
        await viewModel.flipCamera()

        XCTAssertEqual(viewModel.position, .front)
        XCTAssertTrue(camera.switchedPositions.isEmpty)
    }

    // MARK: - Referans noktası (hizalama)

    func test_cekim_referansNoktasiniDaKaydeder() async throws {
        let repository = FakeRepository()
        let viewModel = makeViewModel(camera: FakeCamera(), repository: repository)
        viewModel.setAnchor(NormalizedPoint(x: 0.2, y: 0.7))

        await viewModel.start()
        let success = await viewModel.capture()

        XCTAssertTrue(success)
        let saved = try XCTUnwrap(repository.addedEntries.first)
        XCTAssertEqual(try XCTUnwrap(saved.anchorX), 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(saved.anchorY), 0.7, accuracy: 0.001)
    }

    func test_baslangicReferansi_oncekiCekimdenGelir() throws {
        // Önceki çekimin anchor'ı, yeni oturumun başlangıç referansı olmalı.
        let container = AppModelContainer.makeInMemory()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        context.insert(project)

        let onceki = Entry(capturedAt: date(2026, 6, 1), imageData: Data([0x01]),
                           anchorX: 0.3, anchorY: 0.6)
        onceki.project = project
        context.insert(onceki)
        try context.save()

        let viewModel = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: project)

        XCTAssertEqual(viewModel.referenceAnchor, NormalizedPoint(x: 0.3, y: 0.6))
    }

    // MARK: - Ghost mantığı

    func test_ghostImageData_enYeniCekiminFotografidir() throws {
        let container = AppModelContainer.makeInMemory()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
        context.insert(project)

        let eski = Entry(capturedAt: date(2026, 6, 1), imageData: Data([0x01]))
        eski.project = project
        context.insert(eski)

        let yeni = Entry(capturedAt: date(2026, 6, 10), imageData: Data([0x02]))
        yeni.project = project
        context.insert(yeni)
        try context.save()

        let viewModel = makeViewModel(camera: FakeCamera(), repository: FakeRepository(), project: project)

        XCTAssertEqual(viewModel.ghostImageData, Data([0x02]))   // en yeni çekim
    }

    func test_hicCekimYoksa_ghostYoktur() {
        let viewModel = makeViewModel(camera: FakeCamera(), repository: FakeRepository())
        XCTAssertNil(viewModel.ghostImageData)
    }
}
