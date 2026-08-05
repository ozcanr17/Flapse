import AVFoundation
import Foundation
import UIKit

/// Video kategorisi projeler için `TimelapseComposing` implementasyonu: hizalama
/// yapılmaz, klipler zaman sırasına göre sert kesmeyle (hard-cut) birleştirilir.
/// Studio'nun diğer seçenekleri (hız, müzik, tarih damgası/not, en-boy oranı, outro)
/// `TimelapseComposer`'daki aynı `TimelapseExportSettings` üzerinden korunur.
private struct Segment {
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let capturedAt: Date?
}

struct VideoClipComposer: TimelapseComposing {

    func makeVideo(
        from frames: [TimelapseFrame],
        settings: TimelapseExportSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let clips = frames.filter { $0.videoFileURL != nil }
        guard !clips.isEmpty else { throw TimelapseComposerError.notEnoughFrames }

        onProgress(0.05)

        let composition = AVMutableComposition()
        guard
            let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TimelapseComposerError.writerFailed }

        var segments: [Segment] = []

        for frame in clips {
            guard let url = frame.videoFileURL else { continue }
            let asset = AVURLAsset(url: url)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            let start = composition.duration

            try compVideo.insertTimeRange(range, of: videoTrack, at: start)
            if settings.keepsClipAudio,
               let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: start)
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            segments.append(Segment(
                timeRange: CMTimeRange(start: start, duration: duration),
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                capturedAt: frame.capturedAt
            ))
        }
        guard !segments.isEmpty else { throw TimelapseComposerError.notEnoughFrames }

        onProgress(0.25)

        // Hız: `framesPerSecond` fotoğraf modunda "kare başına süre" taşıyıcısıdır;
        // burada normal (4) referans alınarak oynatma hızı çarpanına çevrilir.
        let speedMultiplier = max(0.1, Double(settings.framesPerSecond) / 4.0)
        let clipsRange = CMTimeRange(start: .zero, duration: composition.duration)
        var scaledSegments = segments
        if speedMultiplier != 1 {
            let scaledDuration = CMTimeMultiplyByFloat64(clipsRange.duration, multiplier: 1.0 / speedMultiplier)
            composition.scaleTimeRange(clipsRange, toDuration: scaledDuration)
            let factor = scaledDuration.seconds / max(clipsRange.duration.seconds, 0.0001)
            scaledSegments = segments.map { segment in
                let scaledStart = CMTimeMultiplyByFloat64(segment.timeRange.start, multiplier: factor)
                let scaledDur = CMTimeMultiplyByFloat64(segment.timeRange.duration, multiplier: factor)
                return Segment(
                    timeRange: CMTimeRange(start: scaledStart, duration: scaledDur),
                    naturalSize: segment.naturalSize,
                    preferredTransform: segment.preferredTransform,
                    capturedAt: segment.capturedAt
                )
            }
        }
        let clipsEnd = composition.duration

        // Outro: fotoğraf modundaki aynı görsel kartı, ayrı bir sessiz video segmenti
        // olarak sona eklenir.
        let outroAssets = await TimelapseComposer.outroAssets()
        let journeyDays = Self.journeyDays(for: clips)
        if let outroURL = try? await Self.makeOutroClip(assets: outroAssets, renderSize: settings.renderSize, days: journeyDays) {
            let outroAsset = AVURLAsset(url: outroURL)
            if let outroTrack = try? await outroAsset.loadTracks(withMediaType: .video).first {
                let outroDuration = try await outroAsset.load(.duration)
                try? compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: outroDuration), of: outroTrack, at: clipsEnd)
            }
        }
        let totalDuration = composition.duration

        onProgress(0.5)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = settings.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for segment in scaledSegments {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment.timeRange
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            let transform = Self.fillTransform(
                naturalSize: segment.naturalSize,
                preferredTransform: segment.preferredTransform,
                renderSize: settings.renderSize
            )
            layerInstruction.setTransform(transform, at: segment.timeRange.start)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
        }
        if clipsEnd < totalDuration {
            let outroInstruction = AVMutableVideoCompositionInstruction()
            outroInstruction.timeRange = CMTimeRange(start: clipsEnd, duration: totalDuration - clipsEnd)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            outroInstruction.layerInstructions = [layerInstruction]
            instructions.append(outroInstruction)
        }
        videoComposition.instructions = instructions

        // Tarih/not/uygulama etiketi bindirmesi: CALayer tabanlı overlay, sadece
        // klip segmentleri boyunca (outro kendi metnini zaten içeriyor).
        videoComposition.animationTool = Self.makeAnimationTool(
            segments: scaledSegments,
            totalDuration: totalDuration,
            renderSize: settings.renderSize,
            settings: settings
        )

        onProgress(0.6)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-timelapse-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TimelapseComposerError.writerFailed
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        if let soundtrackURL = settings.soundtrackURL,
           let mix = try? await Self.makeAudioMix(
               compositionAudioTrack: compAudio,
               musicURL: soundtrackURL,
               totalDuration: totalDuration,
               startOffset: settings.soundtrackStartTime
           ) {
            export.audioMix = mix
        }

        try await export.export(to: outputURL, as: .mp4)
        onProgress(1)
        return outputURL
    }

    private static func journeyDays(for frames: [TimelapseFrame]) -> Int {
        guard let first = frames.first?.capturedAt, let last = frames.last?.capturedAt else { return frames.count }
        return max(1, (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
    }

    /// Klibin doğal boyutunu ve yönünü hesaba katarak hedef tuvali dolduran
    /// (kırparak, taşan kısmı budayarak) dönüşüm — hizalama yapılmaz, yalnızca
    /// kadrajı kayıpsız doldurur.
    private static func fillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let visualSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        guard visualSize.width > 0, visualSize.height > 0 else { return preferredTransform }
        let scale = max(renderSize.width / visualSize.width, renderSize.height / visualSize.height)
        let scaledWidth = visualSize.width * scale
        let scaledHeight = visualSize.height * scale
        let tx = (renderSize.width - scaledWidth) / 2 - transformedRect.minX * scale
        let ty = (renderSize.height - scaledHeight) / 2 - transformedRect.minY * scale
        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Sabit süreli (3 sn), fotoğraf modundakiyle birebir aynı outro kartı — sessiz,
    /// tek başına bir video dosyası olarak üretilir ve kompozisyona eklenir.
    private static func makeOutroClip(
        assets: TimelapseComposer.OutroAssets,
        renderSize: CGSize,
        days: Int
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try writeOutroClip(assets: assets, renderSize: renderSize, days: days)
        }.value
    }

    /// `DispatchSemaphore.wait()` senkron bir çağrıdır; Swift 6'da async gövde
    /// içinde uyarı vermemesi için ayrı, senkron bir fonksiyona alınıyor
    /// (fotoğraf modundaki `TimelapseComposer.render` ile aynı desen).
    private static func writeOutroClip(
        assets: TimelapseComposer.OutroAssets,
        renderSize: CGSize,
        days: Int
    ) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-outro-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw TimelapseComposerError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let outputFPS: Int32 = 30
        let outroFrames = Int(Double(outputFPS) * 3.0)
        let base = UIImage(color: assets.canvas, size: renderSize) ?? UIImage()
        var presentationIndex: Int64 = 0
        for step in 0..<outroFrames {
            let t = CGFloat(step) / CGFloat(max(1, outroFrames - 1))
            guard let frame = TimelapseComposer.outroFrame(base: base, t: t, assets: assets, size: renderSize, days: days) else { continue }
            while !input.isReadyForMoreMediaData { usleep(3000) }
            let buffer = try TimelapseComposer.pixelBuffer(for: frame, adaptor: adaptor, width: width, height: height)
            let time = CMTime(value: presentationIndex, timescale: outputFPS)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw TimelapseComposerError.writerFailed }
            presentationIndex += 1
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw TimelapseComposerError.writerFailed }
        return outputURL
    }

    private static func makeAudioMix(
        compositionAudioTrack: AVMutableCompositionTrack,
        musicURL: URL,
        totalDuration: CMTime,
        startOffset: Double
    ) async throws -> AVMutableAudioMix? {
        // Müziği aynı kompozisyona ikinci bir ses parçası olarak ekliyoruz — klip
        // sesini KORUYORUZ, müzik altına düşük seviyede karışan bir altyapı olur.
        guard let composition = compositionAudioTrack.asset as? AVMutableComposition else { return nil }
        guard let compMusic = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let musicAsset = AVURLAsset(url: musicURL)
        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else { return nil }
        let musicDuration = try await musicAsset.load(.duration)
        guard musicDuration.seconds > 0 else { return nil }

        // Kullanıcı bir başlangıç noktası seçtiyse ilk tur oradan başlar; parça
        // sonuna ulaşınca sonraki turlar baştan normal şekilde devam eder
        // (SoundtrackMuxer.mux ile aynı desen).
        let clampedOffset = max(0, min(startOffset, max(0, musicDuration.seconds - 0.1)))
        var sourcePosition = CMTime(seconds: clampedOffset, preferredTimescale: musicDuration.timescale)
        var cursor = CMTime.zero
        while cursor < totalDuration {
            let remaining = totalDuration - cursor
            let remainingSource = musicDuration - sourcePosition
            let chunk = min(remaining, remainingSource)
            guard chunk > .zero else { break }
            try compMusic.insertTimeRange(CMTimeRange(start: sourcePosition, duration: chunk), of: musicTrack, at: cursor)
            cursor = cursor + chunk
            sourcePosition = .zero
        }

        let mix = AVMutableAudioMix()
        let originalParams = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
        originalParams.setVolume(1, at: .zero)

        let musicParams = AVMutableAudioMixInputParameters(track: compMusic)
        musicParams.setVolume(0.35, at: .zero)
        let fadeDuration = CMTime(seconds: SoundtrackMuxer.fadeDuration(for: totalDuration.seconds), preferredTimescale: 600)
        let fadeStart = max(.zero, totalDuration - fadeDuration)
        musicParams.setVolumeRamp(fromStartVolume: 0.35, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration))

        mix.inputParameters = [originalParams, musicParams]
        return mix
    }

    /// Tarih/not/uygulama etiketi metinlerini CALayer overlay olarak ekler. Her
    /// segmentin tarih katmanı, yalnızca o segmentin zaman aralığında görünür
    /// olacak şekilde bir opacity anahtar-kare animasyonuyla gizlenir/gösterilir.
    private static func makeAnimationTool(
        segments: [Segment],
        totalDuration: CMTime,
        renderSize: CGSize,
        settings: TimelapseExportSettings
    ) -> AVVideoCompositionCoreAnimationTool? {
        let overlay = settings.overlay
        guard overlay.showDate || !overlay.note.isEmpty || settings.includesWatermark || overlay.showAppMark else {
            return nil
        }

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.isGeometryFlipped = true
        parentLayer.addSublayer(videoLayer)

        let margin = renderSize.width * 0.03
        let fontSize = renderSize.height * 0.022
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)

        func makeTextLayer(_ string: String, corner: OverlayCorner, kern: CGFloat = 0) -> CALayer? {
            guard !string.isEmpty else { return nil }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
            let textSize = (string as NSString).size(withAttributes: attributes)
            let origin = corner.origin(textSize: textSize, canvas: renderSize, margin: margin)
            let layer = CATextLayer()
            layer.string = NSAttributedString(string: string, attributes: [
                .font: font,
                .kern: kern,
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ])
            layer.frame = CGRect(origin: origin, size: textSize)
            layer.contentsScale = 3
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.6
            layer.shadowRadius = 4
            layer.shadowOffset = CGSize(width: 0, height: 1)
            return layer
        }

        if overlay.showDate {
            for segment in segments {
                guard let date = segment.capturedAt,
                      let layer = makeTextLayer(TimelapseComposer.dateFormatter.string(from: date), corner: overlay.datePosition)
                else { continue }
                layer.opacity = 0
                let visible = CABasicAnimation(keyPath: "opacity")
                visible.fromValue = 1
                visible.toValue = 1
                visible.beginTime = AVCoreAnimationBeginTimeAtZero + segment.timeRange.start.seconds
                visible.duration = max(0.01, segment.timeRange.duration.seconds)
                visible.fillMode = .both
                visible.isRemovedOnCompletion = false
                layer.add(visible, forKey: "showDuringSegment")
                parentLayer.addSublayer(layer)
            }
        }

        if let noteLayer = makeTextLayer(overlay.note, corner: overlay.notePosition) {
            parentLayer.addSublayer(noteLayer)
        }
        if settings.includesWatermark || overlay.showAppMark {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 2]
            let text = "FLAPSE"
            let textSize = (text as NSString).size(withAttributes: attributes)
            let markLayer = CATextLayer()
            markLayer.string = NSAttributedString(string: text, attributes: [
                .font: font,
                .kern: 2,
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ])
            markLayer.frame = CGRect(
                x: renderSize.width - margin - textSize.width,
                y: renderSize.height - margin - textSize.height,
                width: textSize.width,
                height: textSize.height
            )
            markLayer.contentsScale = 3
            markLayer.shadowColor = UIColor.black.cgColor
            markLayer.shadowOpacity = 0.6
            markLayer.shadowRadius = 4
            markLayer.shadowOffset = CGSize(width: 0, height: 1)
            parentLayer.addSublayer(markLayer)
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
    }
}

private extension UIImage {
    convenience init?(color: UIColor, size: CGSize) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }
}
