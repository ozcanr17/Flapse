import AVFoundation
import Foundation
import UIKit

@MainActor
@Observable
final class TimelapseExportViewModel {

    enum Phase: Equatable {
        case idle
        case rendering
        case finished(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var failedInBackground = false

    private let composer: any TimelapseComposing
    private var renderTask: Task<Void, Never>?
    private var retryAction: (() -> Void)?

    init(composer: any TimelapseComposing = TimelapseComposer()) {
        self.composer = composer
    }

    func export(
        frames: [TimelapseFrame],
        isPro: Bool,
        speed: TimelapseSpeed = .normal,
        speedMultiplier: Double? = nil,
        aspect: TimelapseAspect = .threeFour,
        zoom: Double = 1,
        soundtrackURL: URL? = nil,
        bundledBeats: [Double]? = nil,
        beatSync: Bool = false,
        soundtrackStartTime: Double = 0,
        keepsClipAudio: Bool = true,
        overlay: TimelapseOverlayOptions = TimelapseOverlayOptions(),
        smartAlignment: Bool = false,
        manualAnchor: ManualAlignment? = nil,
        manualAnchors: [ManualAlignment]? = nil,
        transition: TimelapseTransition = .cut,
        alignmentSubject: AlignmentSubject = .auto
    ) {
        renderTask?.cancel()
        guard frames.count >= 2 else {
            retryAction = nil
            phase = .failed(String(localized: "Timelapse için en az 2 çekim gerekli.", bundle: .appLanguage))
            return
        }
        let composer = composer
        phase = .rendering
        progress = 0
        failedInBackground = false
        retryAction = { [weak self] in
            self?.export(
                frames: frames, isPro: isPro, speed: speed, speedMultiplier: speedMultiplier,
                aspect: aspect, zoom: zoom, soundtrackURL: soundtrackURL, bundledBeats: bundledBeats,
                beatSync: beatSync, soundtrackStartTime: soundtrackStartTime, keepsClipAudio: keepsClipAudio,
                overlay: overlay, smartAlignment: smartAlignment,
                manualAnchor: manualAnchor, manualAnchors: manualAnchors,
                transition: transition, alignmentSubject: alignmentSubject
            )
        }
        renderTask = Task { [weak self] in
            do {
                var beats: [Double]? = nil
                if beatSync, let soundtrackURL {
                    if let bundledBeats {
                        beats = bundledBeats
                    } else {
                        beats = try? await AudioBeatAnalyzer.beats(in: soundtrackURL)
                    }
                    if beats?.count ?? 0 < 2 { beats = nil }
                    if let raw = beats {
                        // Kullanıcı bir başlangıç noktası seçtiyse, vuruşlar da o noktaya
                        // göre kaydırılır — aksi halde kesimler duyduğunuz müzikle uyuşmaz.
                        let shifted = soundtrackStartTime > 0
                            ? raw.compactMap { $0 >= soundtrackStartTime ? $0 - soundtrackStartTime : nil }
                            : raw
                        let audioDuration = (try? await AVURLAsset(url: soundtrackURL).load(.duration).seconds) ?? 0
                        beats = shifted.count >= 2
                            ? Self.loopedCutTimes(
                                beats: shifted,
                                frameCount: frames.count,
                                audioDuration: max(0, audioDuration - soundtrackStartTime)
                            )
                            : nil
                    }
                }
                let transitionPlan = transition == .adaptive
                    ? await Task.detached(priority: .userInitiated) {
                        AdaptiveEditEngine.transitionPlan(for: frames)
                    }.value
                    : nil
                let settings = TimelapseExportSettings.current(
                    isPro: isPro, speed: speed, speedMultiplier: speedMultiplier, aspect: aspect, zoom: zoom, overlay: overlay,
                    smartAlignment: smartAlignment, manualAnchor: manualAnchor, manualAnchors: manualAnchors,
                    transition: transition, transitionPlan: transitionPlan,
                    alignmentSubject: alignmentSubject,
                    soundtrackURL: soundtrackURL,
                    beatTimes: beats,
                    soundtrackStartTime: soundtrackStartTime
                )
                let url = try await composer.makeVideo(
                    from: frames,
                    settings: settings,
                    onProgress: { [weak self] value in
                        guard let self else { return }
                        Task { @MainActor in
                            guard self.renderTask?.isCancelled == false else { return }
                            self.progress = value
                        }
                    }
                )
                try Task.checkCancellation()
                self?.phase = .finished(url)
                self?.retryAction = nil
                self?.renderTask = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if UIApplication.shared.applicationState != .active {
                    self?.failedInBackground = true
                } else {
                    self?.retryAction = nil
                }
                self?.phase = .failed(String(localized: "Video oluşturulamadı: \(error.localizedDescription)", bundle: .appLanguage))
                self?.renderTask = nil
            }
        }
    }

    /// Render sonrası müzik senkronu ayarlandığında (yalnızca ses yeniden muxlanmış,
    /// görsel render tekrarlanmamış) sonucu doğrudan `.finished` fazına uygular.
    func applyResyncedOutput(_ url: URL) {
        guard case .finished = phase else { return }
        phase = .finished(url)
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
        retryAction = nil
        failedInBackground = false
        if phase == .rendering {
            phase = .idle
            progress = 0
        }
    }

    func pauseForBackgroundExpiration() {
        guard phase == .rendering else { return }
        failedInBackground = true
        renderTask?.cancel()
        renderTask = nil
        phase = .idle
    }

    static func loopedCutTimes(beats: [Double], frameCount: Int, audioDuration: Double) -> [Double] {
        let source = beats.filter { $0.isFinite && $0 > 0 }.sorted().reduce(into: [Double]()) { result, value in
            if result.last.map({ value - $0 > 0.01 }) ?? true { result.append(value) }
        }
        guard source.count >= 2, frameCount >= 2 else { return source }
        var extended = source
        if audioDuration > 0 {
            var offset = audioDuration
            while extended.count < frameCount {
                for beat in source where extended.count < frameCount {
                    extended.append(beat + offset)
                }
                offset += audioDuration
            }
        } else {
            var gaps: [Double] = []
            for i in 1..<source.count { gaps.append(source[i] - source[i - 1]) }
            while extended.count < frameCount {
                extended.append((extended.last ?? 0) + gaps[(extended.count - 1) % gaps.count])
            }
        }
        return Array(extended.prefix(frameCount))
    }

    func waitForRender() async {
        await renderTask?.value
    }

    func retryAfterBackgroundFailure() -> Bool {
        guard failedInBackground, retryAction != nil else { return false }
        failedInBackground = false
        retryAction?()
        return true
    }
}
