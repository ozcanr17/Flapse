import SwiftUI
import SwiftData
import AVKit
import Photos
import StoreKit

struct TimelapseExportSheet: View {

    let project: Project
    private let viewModel: TimelapseExportViewModel

    @MainActor
    init(project: Project) {
        self.project = project
        let viewModel = TimelapseRenderService.shared.viewModel(for: project)
        self.viewModel = viewModel
        let smartOn = UserDefaults.standard.object(forKey: PremiumFeature.smartAlignment.preferenceKey!) as? Bool ?? true
        _alignMode = State(initialValue: smartOn ? .smart : .off)
        if case .finished(let url) = viewModel.phase {
            _lastRenderedURL = State(initialValue: url)
            _isStale = State(initialValue: false)
        }
    }

    @Environment(StoreService.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @State private var keepsClipAudio = true
    @State private var showPaywall = false
    @State private var speedX: Double = 1.0
    @State private var zoomX: Double = 1.0
    @State private var soundtrackTitle: String?
    @State private var soundtrackURL: URL?
    @State private var bundledBeats: [Double]?
    @State private var beatSync = false
    @State private var isPickingMusic = false
    @State private var soundtrackStartTime: Double = 0
    @State private var isAdjustingStart = false
    @State private var isAdjustingSyncAfterRender = false
    @State private var aiCaption: String?
    @State private var isWritingCaption = false
    @State private var aspect: TimelapseAspect = .threeFour
    @State private var overlay = TimelapseOverlayOptions()
    @State private var noteDraft = ""
    @State private var lastRenderedURL: URL?
    @State private var alignMode: AlignMode = .off
    @State private var manual = ManualAlignment(center: CGPoint(x: 0.5, y: 0.5), zoom: 1)
    @State private var manuals: [ManualAlignment] = []
    @State private var transition: TimelapseTransition = .cut
    @State private var showManualAlign = false
    @State private var isStale = true
    @State private var poster: UIImage?
    @State private var savedToPhotos = false
    @State private var savedToLibrary = false
    @State private var showPhotosDenied = false
    @Environment(\.requestReview) private var requestReview
    @AppStorage("review.promptedVersion") private var reviewPromptedVersion = ""

    private var captionDayCount: Int {
        guard let first = frames.first?.capturedAt, let last = frames.last?.capturedAt else { return frames.count }
        return max(1, (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
    }

    @State private var frames: [TimelapseFrame] = []
    @State private var framesLoaded = false

    private func loadFrames() async {
        var result: [TimelapseFrame] = []
        for entry in project.sortedEntries {
            if let data = entry.imageData {
                result.append(TimelapseFrame(imageData: data, capturedAt: entry.capturedAt, videoFileURL: entry.videoFileURL))
            }
            await Task.yield()
        }
        frames = result
        framesLoaded = true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.canvas.ignoresSafeArea()
                content
            }
            .navigationTitle("Timelapse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
            .task {
                if !framesLoaded {
                    await loadFrames()
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: store)
            }
            .photosDeniedAlert(isPresented: $showPhotosDenied)
            .sheet(isPresented: $showManualAlign) {
                if !frames.isEmpty {
                    ManualAlignView(
                        imagesData: frames.map(\.imageData),
                        ratio: aspect.ratio,
                        manuals: $manuals
                    ) {
                        isStale = true
                    }
                }
            }
            .sheet(isPresented: $isAdjustingSyncAfterRender) {
                if case .finished(let url) = viewModel.phase, let soundtrackURL {
                    PostRenderSyncSheet(
                        videoURL: url,
                        soundtrackURL: soundtrackURL,
                        initialOffset: soundtrackStartTime
                    ) { newURL, newOffset in
                        soundtrackStartTime = newOffset
                        viewModel.applyResyncedOutput(newURL)
                        lastRenderedURL = newURL
                        savedToPhotos = false
                        savedToLibrary = false
                    }
                }
            }
        }
    }

    private var isRendering: Bool { viewModel.phase == .rendering }

    private var content: some View {
        ScrollViewReader { proxy in
            scrollBody(proxy)
        }
    }

    private func scrollBody(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                previewArea
                    .id("previewArea")

                actionArea

                VStack(spacing: 18) {
                    speedControl
                    if !isVideoMode {
                        zoomControl
                    }
                    aspectControl
                    if isVideoMode {
                        clipAudioControl
                    }
                    musicControl
                    if !isVideoMode {
                        transitionControl
                        alignmentControl
                    }
                    overlayControls
                }
                .disabled(isRendering)
                .opacity(isRendering ? 0.45 : 1)
                .animation(.smooth(duration: 0.25), value: isRendering)

                if !store.isPro {
                    Button {
                        showPaywall = true
                    } label: {
                        Text("Filigranı kaldır, 4K'ya geç — Pro")
                            .font(Theme.caption(13))
                            .foregroundStyle(theme.secondary)
                    }
                }
            }
            .padding(20)
        }
        .contentMargins(.bottom, 40, for: .scrollContent)
        .onChange(of: overlay) { isStale = true }
        .onChange(of: viewModel.phase) {
            if case .finished(let url) = viewModel.phase {
                lastRenderedURL = url
                isStale = false
            }
            if viewModel.phase == .rendering {
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("previewArea", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        Group {
            if aspect.ratio <= 1 {
                previewContent
                    .frame(width: 380 * aspect.ratio, height: 380)
                    .frame(maxWidth: .infinity)
            } else {
                previewContent
                    .aspectRatio(aspect.ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: aspect)
    }

    private var previewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(theme.surface)

            switch viewModel.phase {
            case .rendering:
                VStack(spacing: 14) {
                    SpinningLogo(size: 88)
                    Text("Timelapse hazırlanıyor… %\(Int(viewModel.progress * 100))")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                }
            case .finished(let url):
                ExportedVideoPlayer(url: url)
                    .id(url)
            case .failed(let message):
                failedView(message)
            case .idle:
                posterPreview
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .clipped()
    }

    private var posterPreview: some View {
        ZStack {
            if let poster {
                if project.isCoupleMode {
                    Image(uiImage: poster).resizable().scaledToFit()
                } else {
                    Image(uiImage: poster).resizable().scaledToFill()
                }
            }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Ayarları seç, sonra oluştur")
                    .font(Theme.caption(13))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .allowsHitTesting(false)
        .task(id: project.sortedEntries.last?.imageCacheKey) {
            poster = await ImageDownsampler.image(from: frames.last?.imageData, maxPixelSize: 800)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if isRendering {
            VStack(spacing: 10) {
                Button(role: .destructive) {
                    TimelapseRenderService.shared.cancel(projectID: project.id)
                } label: {
                    Label("İptal Et", systemImage: "xmark.circle.fill")
                        .font(Theme.headline(17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .liquidGlassStyle(cornerRadius: 14, tint: Color(red: 0.86, green: 0.22, blue: 0.2), interactive: true)
                .accessibilityIdentifier("cancelRenderButton")
                Text("Uygulamadan çıksan da oluşturma sürer; biten video Kaydedilenler'e düşer.")
                    .font(Theme.caption(11))
                    .foregroundStyle(theme.inkMuted)
                    .multilineTextAlignment(.center)
            }
        } else if case .finished(let url) = viewModel.phase, !isStale {
            VStack(spacing: 10) {
                ShareLink(item: url) {
                    Label("Videoyu Paylaş", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.flapsePrimary)
                if soundtrackURL != nil {
                    Button {
                        isAdjustingSyncAfterRender = true
                    } label: {
                        Label("Müzik Senkronunu Ayarla", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(theme.accent)
                            .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    saveVideoToPhotos(url)
                } label: {
                    Label(savedToPhotos ? "Fotoğraflara kaydedildi" : "Fotoğraflara kaydet",
                          systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(theme.accent)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(savedToPhotos)
                Button {
                    Task {
                        savedToLibrary = await TimelapseRenderService.shared.saveToLibrary(projectID: project.id, context: modelContext) != nil
                        if savedToLibrary {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            promptReviewIfDue()
                        }
                    }
                } label: {
                    Label(savedToLibrary ? "Kaydedilenler'e eklendi" : "Uygulamada sakla",
                          systemImage: savedToLibrary ? "checkmark.circle.fill" : "film.stack")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(theme.accent)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(savedToLibrary)
                .accessibilityIdentifier("saveToLibraryButton")
                if CaptionWriter.isAvailable {
                    if let aiCaption {
                        VStack(spacing: 6) {
                            Text(aiCaption)
                                .font(Theme.body(14))
                                .foregroundStyle(theme.ink)
                                .multilineTextAlignment(.center)
                            Button {
                                UIPasteboard.general.string = aiCaption
                            } label: {
                                Label("Kopyala", systemImage: "doc.on.doc")
                                    .font(Theme.caption(13))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .liquidGlassStyle(cornerRadius: 14)
                    } else {
                        Button {
                            isWritingCaption = true
                            Task {
                                aiCaption = await CaptionWriter.caption(
                                    title: project.title,
                                    frames: frames.count,
                                    days: captionDayCount
                                )
                                isWritingCaption = false
                            }
                        } label: {
                            Label(isWritingCaption ? String(localized: "Metin hazırlanıyor…", bundle: .appLanguage) : String(localized: "AI paylaşım metni", bundle: .appLanguage),
                                  systemImage: "sparkles")
                                .font(Theme.caption(13))
                                .foregroundStyle(theme.accent)
                        }
                        .disabled(isWritingCaption)
                    }
                }
                Button {
                    export()
                } label: {
                    Label("Yeniden Oluştur", systemImage: "arrow.clockwise")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                }
            }
        } else {
            VStack(spacing: 6) {
                Button {
                    export()
                } label: {
                    Label(createTitle, systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.flapsePrimary)
                .disabled(!framesLoaded || frames.count < 2)
                if framesLoaded && frames.count < 2 {
                    Text("Timelapse için en az 2 kare gerekli.")
                        .font(Theme.caption(12))
                        .foregroundStyle(theme.inkMuted)
                }
            }
        }
    }

    private var createTitle: LocalizedStringKey {
        if case .failed = viewModel.phase { return "Tekrar Dene" }
        return lastRenderedURL == nil ? "Timelapse Oluştur" : "Yeniden Oluştur"
    }

    private var speedControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Hız", systemImage: "gauge.with.needle")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text("\(speedX.formatted(.number.precision(.fractionLength(0...2))))×")
                    .font(Theme.caption(13)).monospacedDigit()
                    .foregroundStyle(theme.ink)
            }
            Slider(value: $speedX, in: 0.25...3, step: 0.25)
                .tint(theme.accent)
                .disabled(viewModel.phase == .rendering)
                .onChange(of: speedX) {
                    isStale = true
                }
        }
    }

    private var zoomControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Yakınlaştırma", systemImage: "plus.magnifyingglass")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Text("\(zoomX.formatted(.number.precision(.fractionLength(0...2))))×")
                    .font(Theme.caption(13)).monospacedDigit()
                    .foregroundStyle(theme.ink)
            }
            Slider(value: $zoomX, in: 0.5...(project.isCoupleMode ? 1 : 2), step: 0.05)
                .tint(theme.accent)
                .disabled(viewModel.phase == .rendering)
                .onChange(of: zoomX) {
                    isStale = true
                }
        }
    }

    private var aspectControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Oran", systemImage: "aspectratio")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
            }
            Picker("Oran", selection: $aspect) {
                ForEach(TimelapseAspect.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.phase == .rendering)
            .onChange(of: aspect) {
                isStale = true
            }
        }
    }

    private var musicControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Müzik", systemImage: "music.note")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                Button {
                    if store.isPro { isPickingMusic = true } else { showPaywall = true }
                } label: {
                    Text(soundtrackTitle ?? String(localized: "Kapalı", bundle: .appLanguage))
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.phase == .rendering)
            }
            if soundtrackURL != nil {
                Toggle(isOn: $beatSync) {
                    Label("Ritme senkronla", systemImage: "waveform.path")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                }
                .tint(theme.accent)
                .disabled(viewModel.phase == .rendering)
                .onChange(of: beatSync) { isStale = true }

                Button {
                    isAdjustingStart = true
                } label: {
                    Label(startTimeLabel, systemImage: "timeline.selection")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.inkMuted)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.phase == .rendering)
            }
        }
        .sheet(isPresented: $isPickingMusic) {
            MusicPickerSheet(selectedTitle: soundtrackTitle) { url, title, beats in
                setSoundtrack(url, title: title, beats: beats)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isAdjustingStart) {
            if let soundtrackURL {
                MusicTrimSheet(
                    url: soundtrackURL,
                    title: soundtrackTitle ?? "",
                    initialOffset: soundtrackStartTime
                ) { offset in
                    soundtrackStartTime = offset
                    isStale = true
                }
            }
        }
    }

    private var startTimeLabel: String {
        guard soundtrackStartTime > 0 else {
            return String(localized: "Başlangıcı ayarla", bundle: .appLanguage)
        }
        let total = Int(soundtrackStartTime.rounded())
        let formatted = String(format: "%d:%02d", total / 60, total % 60)
        return String(localized: "Başlangıç: \(formatted)", bundle: .appLanguage)
    }

    private func setSoundtrack(_ url: URL?, title: String?, beats: [Double]? = nil) {
        if url != nil, !store.isPro {
            showPaywall = true
            return
        }
        soundtrackURL = url
        soundtrackTitle = title
        bundledBeats = beats
        beatSync = url != nil
        soundtrackStartTime = 0
        isStale = true
    }

    private var transitionControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Geçiş", systemImage: "square.on.square.dashed")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
            }
            Picker("Geçiş", selection: $transition) {
                ForEach(TimelapseTransition.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.phase == .rendering)
            .onChange(of: transition) {
                if transition == .morph || transition == .adaptive, !store.isPro {
                    transition = .smooth
                    showPaywall = true
                }
                isStale = true
            }
        }
    }

    private var alignmentControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Hizalama", systemImage: "wand.and.stars")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)
                Spacer()
                if !store.isPro {
                    Text("PRO").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accent, in: Capsule())
                }
            }
            Picker("Hizalama", selection: $alignMode) {
                ForEach(AlignMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.phase == .rendering)
            .onChange(of: alignMode) { _, mode in
                if mode == .manual {
                    if !store.isPro {
                        alignMode = .smart
                        showPaywall = true
                        return
                    }
                    if manuals.count != frames.count {
                        manuals = Array(repeating: manual, count: frames.count)
                    }
                    showManualAlign = true
                } else {
                    isStale = true
                }
            }
            if alignMode == .manual {
                Button {
                    showManualAlign = true
                } label: {
                    Label("Hizalamayı Ayarla", systemImage: "scope")
                        .font(Theme.caption(13))
                        .foregroundStyle(theme.accent)
                }
            } else if alignMode == .smart, project.isCoupleMode {
                Text("İlk referans karedeki kişi sırası korunur; gerekirse kare otomatik çevrilir.")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bindirmeler")
                .font(Theme.caption(13))
                .foregroundStyle(theme.inkMuted)

            Toggle(isOn: $overlay.showDate) {
                Label("Tarih damgası", systemImage: "calendar")
                    .font(Theme.body(15))
                    .foregroundStyle(theme.ink)
            }
            .tint(theme.accent)
            if overlay.showDate {
                cornerPicker("Tarih konumu", selection: $overlay.datePosition, exclude: [overlay.notePosition])
            }

            Divider().overlay(theme.inkMuted.opacity(0.2))

            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(theme.accent)
                TextField("Not ekle…", text: $noteDraft)
                    .font(Theme.body(15))
                    .foregroundStyle(theme.ink)
                    .submitLabel(.done)
                    .onSubmit { overlay.note = noteDraft }
            }
            if !noteDraft.isEmpty {
                cornerPicker("Not konumu", selection: $overlay.notePosition, exclude: [overlay.datePosition])
                if overlay.note != noteDraft {
                    Button("Notu uygula") { overlay.note = noteDraft }
                        .font(Theme.caption(12))
                        .foregroundStyle(theme.accent)
                }
            }

            Divider().overlay(theme.inkMuted.opacity(0.2))

            Toggle(isOn: $overlay.showAppMark) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uygulama etiketi (sağ alt)").font(Theme.body(15)).foregroundStyle(theme.ink)
                        Text(store.isPro ? "Konum sabit; gizleyebilirsin" : "Ücretsiz sürümde kaldırılamaz")
                            .font(Theme.caption(11)).foregroundStyle(theme.inkMuted)
                    }
                } icon: {
                    Image(systemName: "signature").foregroundStyle(theme.accent)
                }
            }
            .tint(theme.accent)
            .disabled(!store.isPro)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassStyle()
    }

    /// Köşe seçici. Sağ alt (uygulama etiketi) ve `exclude`'daki köşeler seçenek dışıdır;
    /// böylece tarih ile not asla aynı köşeye düşmez.
    private func cornerPicker(_ title: LocalizedStringKey, selection: Binding<OverlayCorner>, exclude: Set<OverlayCorner>) -> some View {
        let reserved = exclude.union([TimelapseOverlayOptions.appMarkCorner])
        let options = OverlayCorner.allCases.filter { $0 == selection.wrappedValue || !reserved.contains($0) }
        return HStack {
            Text(title)
                .font(Theme.caption(12))
                .foregroundStyle(theme.inkMuted)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options) { corner in
                    Text(corner.displayName).tag(corner)
                }
            }
            .pickerStyle(.menu)
            .tint(theme.accent)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(theme.accent)
            Text(message)
                .font(Theme.body(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var alignmentSubject: AlignmentSubject {
        if project.isCoupleMode { return .group }
        switch project.category {
        case .fitness, .outfit: return .body
        case .pregnancy:        return .belly
        default:                return .auto
        }
    }

    private func saveVideoToPhotos(_ url: URL) {
        Task {
            let outcome = await PhotoLibrarySaver.saveVideo(at: url)
            savedToPhotos = outcome == .saved
            if outcome == .denied {
                showPhotosDenied = true
            }
            UINotificationFeedbackGenerator().notificationOccurred(outcome == .saved ? .success : .error)
        }
    }

    private func promptReviewIfDue() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        guard reviewPromptedVersion != version else { return }
        reviewPromptedVersion = version
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            requestReview()
        }
    }

    /// Video kategorisi projede hizalama/geçiş uygulanmaz — klipler yalnızca sert
    /// kesmeyle sırayla birleştirilir; müzik/tarih damgası/en-boy oranı/hız korunur.
    private var isVideoMode: Bool { project.category.isVideoMode }

    /// Video modunda kliplerin kendi sesi korunsun mu?
    private var clipAudioControl: some View {
        Toggle(isOn: $keepsClipAudio) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Klip sesi", systemImage: "waveform")
                    .font(Theme.headline(15))
                Text(keepsClipAudio
                     ? "Kliplerin kendi sesi korunur; müzik altta çalar."
                     : "Yalnızca seçilen müzik duyulur.")
                    .font(Theme.caption(12))
                    .foregroundStyle(theme.inkMuted)
            }
        }
        .tint(theme.accent)
    }

    private func export() {
        savedToPhotos = false
        savedToLibrary = false
        var effectiveOverlay = overlay
        if !store.isPro { effectiveOverlay.showAppMark = true }
        let proAlign = store.isPro
        viewModel.export(
            frames: frames,
            isPro: store.isPro,
            speedMultiplier: speedX,
            aspect: aspect,
            zoom: isVideoMode ? 1 : zoomX,
            soundtrackURL: soundtrackURL,
            bundledBeats: bundledBeats,
            beatSync: beatSync,
            soundtrackStartTime: soundtrackStartTime,
            keepsClipAudio: keepsClipAudio,
            overlay: effectiveOverlay,
            smartAlignment: !isVideoMode && alignMode == .smart,
            manualAnchor: (!isVideoMode && proAlign && alignMode == .manual) ? manual : nil,
            manualAnchors: (!isVideoMode && proAlign && alignMode == .manual && manuals.count == frames.count) ? manuals : nil,
            transition: isVideoMode ? .cut : transition,
            alignmentSubject: alignmentSubject
        )
        TimelapseRenderService.shared.didStartRender(for: project)
    }
}

private enum AlignMode: String, CaseIterable, Identifiable {
    case off, smart, manual
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off:    String(localized: "Kapalı", bundle: .appLanguage)
        case .smart:  String(localized: "Akıllı", bundle: .appLanguage)
        case .manual: String(localized: "Manuel", bundle: .appLanguage)
        }
    }
}

/// Manuel hizalama ekranı — WYSIWYG. Kutu, videonun çıktısıyla aynı (3:4) orandadır;
/// kullanıcı fotoğrafı SÜRÜKLEYEREK özneyi ortalar ve yakınlaştırmayı ayarlar. Kutuda
/// ne görüyorsa videoda o olur. Bu seçim tüm karelere uygulanır.
private struct ManualAlignView: View {
    let imagesData: [Data]
    var ratio: CGFloat = 3.0 / 4.0
    @Binding var manuals: [ManualAlignment]
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var index = 0
    @State private var uiImage: UIImage?
    @State private var dragStart: CGPoint?
    @State private var pinchStartZoom: CGFloat?
    @State private var rotationStart: Double?

    private var manual: ManualAlignment {
        get { manuals.indices.contains(index) ? manuals[index] : ManualAlignment(center: CGPoint(x: 0.5, y: 0.5), zoom: 1) }
        nonmutating set { if manuals.indices.contains(index) { manuals[index] = newValue } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Fotoğrafı sürükleyerek özneyi ortala; her kareyi ayrı ayrı hizalayabilirsin")
                    .font(Theme.caption(13))
                    .foregroundStyle(theme.inkMuted)

                GeometryReader { geo in
                    ZStack {
                        Color.black
                        if let uiImage {
                            let disp = displaySize(image: uiImage.size, container: geo.size)
                            let point = CGPoint(x: manual.center.x * disp.width, y: manual.center.y * disp.height)
                            ZStack {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .frame(width: disp.width, height: disp.height)
                                    .position(
                                        x: geo.size.width / 2 + disp.width / 2 - point.x,
                                        y: geo.size.height / 2 + disp.height / 2 - point.y
                                    )
                            }
                            .rotationEffect(.degrees(manual.rotation))
                        }
                        ThirdsReticle()
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard let uiImage else { return }
                                let disp = displaySize(image: uiImage.size, container: geo.size)
                                if dragStart == nil { dragStart = manual.center }
                                let start = dragStart ?? manual.center
                                let nx = start.x - value.translation.width / max(disp.width, 1)
                                let ny = start.y - value.translation.height / max(disp.height, 1)
                                manual.center = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                if pinchStartZoom == nil { pinchStartZoom = manual.zoom }
                                let base = pinchStartZoom ?? manual.zoom
                                manual.zoom = min(max(base * value, 0.5), 3)
                            }
                            .onEnded { _ in pinchStartZoom = nil }
                    )
                    .simultaneousGesture(
                        RotationGesture()
                            .onChanged { value in
                                if rotationStart == nil { rotationStart = manual.rotation }
                                let base = rotationStart ?? manual.rotation
                                manual.rotation = min(max(base + value.degrees, -180), 180)
                            }
                            .onEnded { _ in rotationStart = nil }
                    )
                    .clipped()
                }
                .aspectRatio(ratio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(theme.inkMuted.opacity(0.3), lineWidth: 1)
                )

                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(theme.inkMuted)
                    Slider(value: Binding(get: { Double(manual.zoom) }, set: { manual.zoom = CGFloat($0) }), in: 0.5...3)
                        .tint(theme.accent)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(theme.inkMuted)
                }

                HStack(spacing: 14) {
                    Button {
                        index = max(0, index - 1)
                        dragStart = nil; pinchStartZoom = nil; rotationStart = nil
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(index > 0 ? theme.accent : theme.inkMuted.opacity(0.3))
                    }
                    .disabled(index == 0)
                    .accessibilityLabel(Text("Önceki kare"))

                    Text("\(index + 1) / \(imagesData.count)")
                        .font(Theme.headline(15)).monospacedDigit()
                        .foregroundStyle(theme.ink)
                        .frame(minWidth: 64)

                    Button {
                        index = min(imagesData.count - 1, index + 1)
                        dragStart = nil; pinchStartZoom = nil; rotationStart = nil
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(index < imagesData.count - 1 ? theme.accent : theme.inkMuted.opacity(0.3))
                    }
                    .disabled(index >= imagesData.count - 1)
                    .accessibilityLabel(Text("Sonraki kare"))

                    Spacer()

                    Button("Tümüne Uygula") {
                        let value = manual
                        manuals = Array(repeating: value, count: manuals.count)
                    }
                    .font(Theme.caption(13))
                    .buttonStyle(.bordered)
                    .tint(theme.accent)
                }

                HStack(spacing: 12) {
                    Image(systemName: "rotate.left").foregroundStyle(theme.inkMuted)
                    Slider(
                        value: Binding(get: { manual.rotation }, set: { manual.rotation = $0 }),
                        in: -180...180, step: 1
                    )
                        .tint(theme.accent)
                    Image(systemName: "rotate.right").foregroundStyle(theme.inkMuted)
                }
            }
            .padding(20)
            .background(theme.canvas)
            .navigationTitle("Manuel Hizalama")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Uygula") { dismiss(); onDone() }.fontWeight(.bold)
                }
            }
        }
        .task(id: index) {
            guard imagesData.indices.contains(index) else { return }
            uiImage = await ImageDownsampler.image(from: imagesData[index], maxPixelSize: 1400)
        }
    }

    /// Görselin kutu içindeki gösterim boyutu: doldur (aspect-fill) × zoom. Composer'daki
    /// manualRect ile aynı mantık, böylece önizleme birebir çıktıyı gösterir.
    private func displaySize(image: CGSize, container: CGSize) -> CGSize {
        let fill = max(container.width / max(image.width, 1), container.height / max(image.height, 1))
        let scale = fill * max(manual.zoom, 0.2)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Ortalamaya yardımcı hafif üçler kuralı + merkez nişangâhı.
private struct ThirdsReticle: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    for f in [1.0 / 3.0, 2.0 / 3.0] {
                        path.move(to: CGPoint(x: geo.size.width * f, y: 0))
                        path.addLine(to: CGPoint(x: geo.size.width * f, y: geo.size.height))
                        path.move(to: CGPoint(x: 0, y: geo.size.height * f))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * f))
                    }
                }
                .stroke(.white.opacity(0.28), lineWidth: 1)

                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 22, height: 22)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Video render edilirken gösterilen sevimli, sürekli dönen logo animasyonu
/// (uygulama açılışındaki dönüşle aynı ruhta). Sıkıcı ilerleme çubuğunun yerini alır.
struct SpinningLogo: View {
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        // Dıştaki yuvarlatılmış kare sabit; yalnızca içteki objektif sürekli döner.
        LogoMark(size: size, innerRotation: .degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Oynatıcıyı bir kez oluşturup tutar; her SwiftUI güncellemesinde yeni bir AVPlayer
/// üretmeyi (ve sızıntıyı) önler. `.id(url)` ile URL değişince görünüm yeniden kurulur.
struct ExportedVideoPlayer: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        InlineVideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}

#Preview {
    let container = AppModelContainer.makeInMemory()
    let project = Project(title: "Sakal", category: .hairAndBeard, cadence: .daily)
    container.mainContext.insert(project)
    return TimelapseExportSheet(project: project)
        .modelContainer(container)
        .environment(StoreService())
}
