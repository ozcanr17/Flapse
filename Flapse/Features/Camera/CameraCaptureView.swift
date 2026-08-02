import SwiftUI
import SwiftData
import AVFoundation
import UIKit
import os

struct CameraCaptureView: View {

    var project: Project? = nil
    var retakeEntry: Entry? = nil
    var onAutoCaptured: ((Data) -> Void)? = nil
    var onVideoCaptured: ((URL, Double, Data?) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CameraCaptureViewModel?

    /// Önizleme katmanı bilerek view model'den BAĞIMSIZ tutulur: oturum paylaşılan
    /// tekil nesne olduğundan katman ilk render'da bağlanabilir. Daha önce önizleme
    /// `CameraSessionView`'ın içindeydi ve view model `.task` içinde kurulana kadar
    /// (ki bu kurulum projenin çekimlerini de yüklüyor) ekran tamamen siyah kalıyordu.
    private var previewPosition: AVCaptureDevice.Position {
        viewModel?.position ?? CameraCaptureViewModel.initialPosition(for: project?.category ?? .other)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: CameraService.shared.session, position: previewPosition)
                .aspectRatio(
                    (viewModel?.aspectRatio ?? .ratio16x9).value,
                    contentMode: .fit
                )
                // iPhone Kamera'da alttaki siyah bant üsttekinden bir miktar geniştir;
                // kontroller altta yoğunlaştığı için çerçeve hafifçe yukarı alınır.
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if let viewModel {
                CameraSessionView(viewModel: viewModel, isAuto: onAutoCaptured != nil || onVideoCaptured != nil)
            }
        }
        // Kamera ekranı belirdiği an geçiş göstergesi işini bitirmiştir; bu ekran
        // zaten tam ekran olarak onun üstünde duruyor.
        .onAppear {
            CameraLaunchTrace.mark("camera view onAppear")
            CameraLaunchIndicator.shared.hide()
        }
        .environment(\.colorScheme, .dark)
        .task {
            let t0 = CFAbsoluteTimeGetCurrent()
            CameraLaunchTrace.mark("View.task begin")
            cameraLog.notice("View.task: begin, viewModel already set=\(self.viewModel != nil)")
            guard viewModel == nil else { return }
            let model = CameraCaptureViewModel(
                camera: CameraService.shared,
                repository: ProjectRepository(context: modelContext),
                project: project,
                retakeEntry: retakeEntry,
                onCaptured: onAutoCaptured,
                onVideoCaptured: onVideoCaptured
            )
            viewModel = model
            cameraLog.notice("View.task: viewModel created after \((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
            CameraLaunchTrace.mark("viewModel built")
            await model.start()
            CameraLaunchTrace.end("camera ready")
            cameraLog.notice("View.task: model.start() returned, TOTAL=\((CFAbsoluteTimeGetCurrent() - t0) * 1000, format: .fixed(precision: 1))ms")
        }
        .onDisappear { viewModel?.stop() }
    }
}

private struct CameraSessionView: View {

    let viewModel: CameraCaptureViewModel
    var isAuto: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(StoreService.self) private var store

    @State private var flashOpacity: Double = 0
    /// Odaklamanın dokunmaması gereken alt bölge (zoom + deklanşör + mod anahtarı).
    private static let controlZoneHeight: CGFloat = 260
    @State private var zoomDragBase: CGFloat?
    @State private var isScrubbingZoom = false
    @State private var focusPoint: CGPoint?
    @State private var focusResetTask: Task<Void, Never>?
    @State private var zoomGestureBase: CGFloat?

    /// Çift modu projeye bağlıdır (Birlikte Çekim kategorisi). Akıllı hizalama artık
    /// kamerada değil, dışa aktarımda yüz tespitiyle uygulanır.
    private var coupleMode: Bool { store.isPro && viewModel.isCoupleMode }

    private var isReady: Bool {
        viewModel.state == .ready || viewModel.state == .capturing || viewModel.state == .recording
    }

    private var canInteract: Bool {
        viewModel.state == .ready && !viewModel.isSwitching
    }

    private var isRecording: Bool { viewModel.state == .recording }

    /// Zoom ve odaklama kayıt SIRASINDA da çalışmalı — çekim ortasında kadrajı
    /// değiştirebilmek videonun en temel ihtiyacı.
    private var canAdjustCapture: Bool { canInteract || isRecording }

    private var hasFailed: Bool {
        if case .failed = viewModel.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    // Önizleme katmanı üst seviyede (`CameraCaptureView`) duruyor;
                    // burada yalnızca onun üzerindeki zoom hareketini yakalıyoruz.
                    Color.clear
                        // Alt kontrol bölgesi hariç tutuluyor: daha önce odaklama
                        // katmanı tüm ekranı kapladığı için, mod anahtarını ıskalayan
                        // her dokunuş arkadaki odaklamayı tetikliyordu.
                        .padding(.bottom, Self.controlZoneHeight)
                        .contentShape(Rectangle())
                        .gesture(zoomGesture)
                        .onTapGesture { location in
                            guard canAdjustCapture else { return }
                            let devicePoint = CameraPreviewHost.shared.devicePoint(for: location)
                            viewModel.focus(at: devicePoint)
                            focusPoint = location
                            focusResetTask?.cancel()
                            focusResetTask = Task {
                                try? await Task.sleep(for: .seconds(1.1))
                                guard !Task.isCancelled else { return }
                                focusPoint = nil
                            }
                        }
                        .overlay(alignment: .topLeading) { focusIndicator }

                    if !hasFailed {
                        AlignmentGuideOverlay()
                    }

                }
            }
            .ignoresSafeArea()

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if viewModel.state == .starting {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }

            if case .failed(let message) = viewModel.state {
                errorOverlay(message)
            }

            VStack(spacing: 0) {
                topBar

                if !hasFailed, isRecording {
                    recordingIndicator
                        .padding(.top, 8)
                } else if !hasFailed, coupleMode {
                    activeModeChips
                        .padding(.top, 8)
                }

                Spacer()

                if !hasFailed {
                    VStack(spacing: 16) {
                        zoomControls
                        bottomBar
                        if viewModel.captureMode == .modular {
                            // Kayıt sırasında gizlenir ama YERİ KORUNUR; aksi hâlde
                            // deklanşör ve zoom şeridi aşağı kayıyordu.
                            modeToggle
                                .padding(.top, 3)
                                .opacity(isRecording ? 0 : 1)
                                .allowsHitTesting(!isRecording)
                        }
                    }
                    .padding(.bottom, -2)
                }
            }
        }
        .onDisappear {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }

    /// Duraklara dokunulabilir, üzerinde yatay sürüklenerek sürekli zoom yapılabilir —
    /// iPhone Kamera'daki şerit gibi. Sürükleme sırasında güncel oran ("2,3×") gösterilir.
    private var zoomControls: some View {
        HStack(spacing: 6) {
            ForEach(zoomPresets, id: \.self) { factor in
                let isCurrent = abs(viewModel.zoomFactor - factor) < 0.05
                Button {
                    viewModel.setZoomFactor(factor)
                } label: {
                    Text(isCurrent ? zoomLabel(factor) + "×" : zoomLabel(factor))
                        .font(.system(size: isCurrent ? 15 : 14, weight: .semibold))
                        .foregroundStyle(isCurrent ? .yellow : .white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .frame(width: 44, height: 44)
                        .background {
                            if isCurrent {
                                Circle().fill(.clear).liquidGlassBarCircle()
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canAdjustCapture)
            }
        }
        .padding(.horizontal, 6)
        .background {
            if isScrubbingZoom {
                Capsule().fill(.black.opacity(0.28))
            }
        }
        .overlay(alignment: .top) {
            if isScrubbingZoom || !isOnAStop {
                Text(zoomLabel(viewModel.zoomFactor) + "×")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .liquidGlassBarCapsule()
                    .offset(y: -34)
                    .allowsHitTesting(false)
            }
        }
        .highPriorityGesture(zoomScrubGesture)
        .animation(.smooth(duration: 0.18), value: isScrubbingZoom)
    }

    /// Geçerli zoom, duraklardan birine denk gelmiyorsa oran ayrıca gösterilir —
    /// böylece sürüklerken ve ara değerlerde kaçta olduğumuz her zaman görünür.
    private var isOnAStop: Bool {
        zoomPresets.contains { abs($0 - viewModel.zoomFactor) < 0.05 }
    }

    /// Şerit üzerinde yatay sürükleme: 140 pt'lik hareket zoom aralığının tamamını tarar.
    private var zoomScrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard canAdjustCapture else { return }
                if zoomDragBase == nil {
                    zoomDragBase = viewModel.zoomFactor
                    isScrubbingZoom = true
                }
                let span = viewModel.zoomRange.upperBound - viewModel.zoomRange.lowerBound
                let delta = value.translation.width / 140 * span
                viewModel.setZoomFactor((zoomDragBase ?? 1) + delta, smoothly: false)
            }
            .onEnded { _ in
                zoomDragBase = nil
                isScrubbingZoom = false
            }
    }

    /// Sabit bir liste değil, cihazın kendi optik durakları. Her modelde farklı olur
    /// (ör. 0.5×/1×/3× ya da yalnızca 1×/2×).
    private var zoomPresets: [CGFloat] {
        viewModel.zoomStops.filter { viewModel.zoomRange.contains($0) }
    }

    private func zoomLabel(_ factor: CGFloat) -> String {
        if abs(factor - factor.rounded()) < 0.05 {
            return "\(Int(factor.rounded()))"
        }
        return String(format: "%.1f", Double(factor))
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomGestureBase == nil { zoomGestureBase = viewModel.zoomFactor }
                viewModel.setZoomFactor((zoomGestureBase ?? 1) * value, smoothly: false)
            }
            .onEnded { _ in zoomGestureBase = nil }
    }

    private var topBar: some View {
        HStack {
            CameraControlButton(icon: "xmark", label: "Kapat") { dismiss() }
            Spacer()
            if !hasFailed {
                HStack(spacing: 10) {
                    Button {
                        viewModel.cycleAspectRatio()
                    } label: {
                        Text(viewModel.aspectRatio.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .liquidGlassBarCircle()
                    }
                    .accessibilityLabel(Text("En/boy oranı"))
                    .disabled(isRecording)
                    .opacity(isRecording ? 0.4 : 1)

                    CameraControlButton(icon: viewModel.flashMode.icon, label: "Flaş") {
                        viewModel.cycleFlashMode()
                    }
                    .disabled(!canInteract && !isRecording)
                    .opacity((canInteract || isRecording) ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /// Deklanşör satırı. Tam genişlik mat bir bant YOK: bant, altındaki mod anahtarını
    /// dışarıda bırakıp arayüzü ikiye bölüyordu. Kontroller Apple Kamera'daki gibi
    /// önizlemenin üstünde yüzen cam parçalar hâlinde duruyor.
    private var bottomBar: some View {
        ZStack {
            shutterButton

            HStack {
                Color.clear.frame(width: 52, height: 52)
                Spacer()
                CameraControlButton(icon: "arrow.triangle.2.circlepath.camera", size: 52, label: "Kamerayı çevir") {
                    Task { await viewModel.flipCamera() }
                }
                .disabled(!canInteract)
                .opacity(canInteract ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 28)
    }

    private var activeModeChips: some View {
        HStack(spacing: 8) {
            if coupleMode {
                modeChip("Çift modu", systemImage: "person.2.fill")
            }
        }
    }

    private func modeChip(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlassBarCapsule()
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }

    @State private var recordingElapsed: Int = 0
    @State private var elapsedTimer: Timer?
    @State private var isPressing = false
    @State private var holdTimer: Timer?
    @State private var recordingProgress: Double = 0

    /// Bu süreden uzun basış "video kaydı" sayılır; altındaki her dokunuş fotoğraf.
    private static let holdThreshold: TimeInterval = 0.28

    /// Deklanşör, projenin türüyle uyumlu tek bir iş yapar; yalnızca ana ekrandan
    /// açılan modüler çekimde hem fotoğraf hem video verir.
    @ViewBuilder
    private var shutterButton: some View {
        switch viewModel.captureMode {
        case .videoOnly: videoShutter
        case .photoOnly: photoShutter
        case .modular:   modularShutter
        }
    }

    /// Video projesi: Apple Kamera'daki gibi kırmızı kayıt düğmesi — dokun başlat,
    /// tekrar dokun durdur. Basılı tutmaya gerek yok.
    private var videoShutter: some View {
        shutterBody(ringColor: isRecording ? .red : .white, core: .red)
            .contentShape(Circle())
            .onTapGesture {
                if isRecording {
                    Task { await finishRecording() }
                } else {
                    beginRecording()
                }
            }
            .modifier(ShutterChrome(
                enabled: canInteract || isRecording,
                label: isRecording
                    ? String(localized: "Kaydı durdur", bundle: .appLanguage)
                    : String(localized: "Video kaydet", bundle: .appLanguage)
            ))
    }

    /// Fotoğraf projesi: eskisi gibi, yalnızca dokun.
    private var photoShutter: some View {
        shutterBody(ringColor: .white, core: .white)
            .contentShape(Circle())
            .onTapGesture { Task { await captureTapped() } }
            .modifier(ShutterChrome(
                enabled: canInteract,
                label: String(localized: "Fotoğraf çek", bundle: .appLanguage)
            ))
    }

    /// Ana ekran (modüler): üstteki anahtar hangi moddaysa deklanşör onu yapar.
    private var modularShutter: some View {
        let isVideo = viewModel.captureKind == .video
        return shutterBody(
            ringColor: isRecording ? .red : .white,
            core: isVideo ? .red : .white
        )
        .contentShape(Circle())
        .onTapGesture {
            if isVideo {
                if isRecording {
                    Task { await finishRecording() }
                } else {
                    beginRecording()
                }
            } else {
                Task { await captureTapped() }
            }
        }
        .modifier(ShutterChrome(
            enabled: canInteract || isRecording,
            label: isVideo
                ? String(localized: "Video kaydet", bundle: .appLanguage)
                : String(localized: "Fotoğraf çek", bundle: .appLanguage)
        ))
    }

    /// Fotoğraf/Video anahtarı — yalnızca ana ekran kamerasında.
    private var modeToggle: some View {
        HStack(spacing: 6) {
            modeToggleButton(.video, String(localized: "Video", bundle: .appLanguage))
            modeToggleButton(.photo, String(localized: "Fotoğraf", bundle: .appLanguage))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .liquidGlassBarCapsule()
    }

    private func modeToggleButton(
        _ kind: CameraCaptureViewModel.CaptureKind,
        _ title: String
    ) -> some View {
        let isSelected = viewModel.captureKind == kind
        return Button {
            cameraLog.notice("MODESWITCH dokunuldu → \(String(describing: kind))")
            viewModel.setCaptureKind(kind)
        } label: {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .yellow : .white.opacity(0.85))
                .padding(.horizontal, 20)
                // Dokunma alanı Apple'daki gibi 44 pt'nin üstünde: ıskalayan
                // dokunuşlar "anahtar çalışmıyor" hissi veriyordu.
                .frame(height: 36)
                .background {
                    if isSelected {
                        Capsule().strokeBorder(.yellow.opacity(0.9), lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(kind == .photo ? "cameraModePhoto" : "cameraModeVideo")
    }

    private func shutterBody(ringColor: Color, core: Color) -> some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: 4)
                .frame(width: 74, height: 74)

            if isRecording {
                Circle()
                    .trim(from: 0, to: recordingProgress)
                    .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 74, height: 74)
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.red)
                    .frame(width: 28, height: 28)
            } else {
                Circle()
                    .fill(core)
                    .frame(width: 60, height: 60)
                    .scaleEffect(isPressing ? 0.88 : 1)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isRecording)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isPressing)
    }

    /// `minimumDistance: 0` bir DragGesture, hem dokunuşu hem basılı tutmayı tek
    /// yerden yönetir: parmak değdiği anda eşik sayacı başlar, eşiği geçerse kayıt
    /// başlar, parmak kalkınca ya kayıt biter ya da fotoğraf çekilir.
    private var holdShutterGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressing else { return }
                isPressing = true
                scheduleHoldToRecord()
            }
            .onEnded { _ in
                isPressing = false
                releaseShutter()
            }
    }

    private func scheduleHoldToRecord() {
        holdTimer?.invalidate()
        guard viewModel.canRecordVideo else { return }
        Task { await viewModel.prepareMicrophoneForHold() }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { _ in
            beginRecording()
        }
    }

    private func releaseShutter() {
        holdTimer?.invalidate()
        holdTimer = nil
        if isRecording {
            Task { await finishRecording() }
        } else if viewModel.canCapturePhoto {
            Task {
                await captureTapped()
                await viewModel.releaseMicrophoneIfIdle()
            }
        }
    }

    private var shutterHint: some View {
        Text(String(localized: "Fotoğraf için dokun, video için basılı tut", bundle: .appLanguage))
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlassBarCapsule()
    }

    private func beginRecording() {
        guard canInteract else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recordingElapsed = 0
        recordingProgress = 0
        elapsedTimer?.invalidate()
        let start = Date()
        let maxDuration = CameraCaptureViewModel.maxVideoDuration
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(start)
            recordingElapsed = Int(elapsed)
            recordingProgress = min(elapsed / maxDuration, 1)
            // Donanımın azami süreye ulaşıp kendiliğinden kesmesinden hemen önce
            // uygulama tarafında güvenli biçimde durdur (yarış durumunu önler).
            if elapsed >= maxDuration - 0.3 {
                elapsedTimer?.invalidate()
                elapsedTimer = nil
                Task { await finishRecording() }
            }
        }
        Task {
            await viewModel.startVideoRecording()
            if viewModel.state != .recording {
                // İzin reddi veya donanım hatası.
                elapsedTimer?.invalidate()
                elapsedTimer = nil
                recordingElapsed = 0
                recordingProgress = 0
            }
        }
    }

    private func finishRecording() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingElapsed = 0
        recordingProgress = 0
        let saved = await viewModel.finishVideoRecording()
        if saved {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if !isAuto { dismiss() }
        }
    }

    private struct ShutterChrome: ViewModifier {
        let enabled: Bool
        let label: String

        func body(content: Content) -> some View {
            content
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
                .accessibilityIdentifier("cameraShutter")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(label))
        }
    }

    /// Dokunulan noktada beliren odak karesi — Apple Kamera'daki gibi sade, sarı,
    /// kısa süre sonra kendiliğinden kaybolur.
    @ViewBuilder
    private var focusIndicator: some View {
        if let focusPoint {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)
                .position(focusPoint)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var recordingIndicator: some View {
        Text(Self.formatElapsed(recordingElapsed))
            .font(.system(size: 17, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(red: 0.93, green: 0.30, blue: 0.26), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(Text("Kayıt süresi"))
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func captureTapped() async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.08)) { flashOpacity = 0.75 }
        let saved = await viewModel.capture()
        withAnimation(.easeOut(duration: 0.25)) { flashOpacity = 0 }
        if saved {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if !isAuto { dismiss() }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(message)
                .multilineTextAlignment(.center)
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                Button("Ayarları Aç") { PhotoLibrarySaver.openSettings() }
                    .buttonStyle(.flapsePrimary)
                    .frame(width: 200)
            }
            Button("Kapat") { dismiss() }
                .font(Theme.body(15))
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(24)
    }
}

private struct AlignmentGuideOverlay: View {
    var body: some View {
        ThirdsGridShape()
            .stroke(.white.opacity(0.28), lineWidth: 1)
        .allowsHitTesting(false)
    }
}

private struct ThirdsGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            path.move(to: CGPoint(x: rect.width * fraction, y: 0))
            path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}

struct CameraControlButton: View {
    let icon: String
    var size: CGFloat = 42
    var label: LocalizedStringKey = "Düğme"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .liquidGlassBarCircle()
        }
        .accessibilityLabel(Text(label))
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let position: AVCaptureDevice.Position

    /// Görünüm paylaşılan, önceden kurulmuş katmandır — burada oturum ataması YOK.
    func makeUIView(context: Context) -> CameraPreviewHost.PreviewView {
        CameraLaunchTrace.mark("preview view adopted")
        CameraPreviewHost.shared.setMirrored(position == .front)
        return CameraPreviewHost.shared.view
    }

    func updateUIView(_ uiView: CameraPreviewHost.PreviewView, context: Context) {
        CameraPreviewHost.shared.setMirrored(position == .front)
    }
}

