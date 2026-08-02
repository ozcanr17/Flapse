import Accelerate
import AVFoundation
import Foundation

/// Videoya eklenecek müzik kaynağı: uygulamayla gelen parçalardan biri ya da
/// kullanıcının Dosyalar'dan seçtiği kendi dosyası.
struct SoundtrackOption: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
    /// Sentezlenmiş parçaların bilinen vuruş aralığı (sn). Analize gerek kalmadan
    /// kusursuz ritim senkronu sağlar.
    let beatInterval: Double?

    var beatGrid: [Double]? {
        guard let beatInterval else { return nil }
        return stride(from: beatInterval, through: 24.0, by: beatInterval).map { $0 }
    }

    static var bundled: [SoundtrackOption] {
        let names: [(file: String, title: String, beat: Double?)] = [
            ("calm", String(localized: "Sakin", bundle: .appLanguage), 1.5),
            ("joyful", String(localized: "Neşeli", bundle: .appLanguage), 0.5),
            ("upbeat", String(localized: "Tempolu", bundle: .appLanguage), 0.6),
            ("sad", String(localized: "Hüzünlü", bundle: .appLanguage), 60.0 / 70.0),
            ("cinematic", String(localized: "Sinematik", bundle: .appLanguage), 2.0),
            ("dreamy", String(localized: "Rüya gibi", bundle: .appLanguage), 1.2),
            ("warm", String(localized: "Sıcak", bundle: .appLanguage), 0.8),
            ("minimal", String(localized: "Minimal", bundle: .appLanguage), 1.0)
        ]
        return names.compactMap { entry in
            guard let url = Bundle.main.url(forResource: entry.file, withExtension: "m4a")
                ?? Bundle.main.url(forResource: entry.file, withExtension: "m4a", subdirectory: "Soundtracks")
            else { return nil }
            return SoundtrackOption(id: entry.file, title: entry.title, url: url, beatInterval: entry.beat)
        }
    }
}

/// Kullanıcının Dosyalar'dan seçtiği parçaların son kullanılanlar listesi. Her proje
/// için yeniden Dosyalar'a gitmemesi için, dönüştürülmüş (AAC) dosya kalıcı depoya
/// kopyalanır ve küçük bir liste `UserDefaults`'ta tutulur (`TimelapseLibrary`/
/// `VideoEntryStorage` ile aynı dosya-tabanlı depolama deseni).
enum RecentSoundtracks {
    private static let key = "recentSoundtracks.v1"
    private static let maxCount = 8

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecentSoundtracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let addedAt: Date

        var url: URL { RecentSoundtracks.directory.appendingPathComponent(id) }
    }

    static func all() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    @discardableResult
    static func add(sourceURL: URL, title: String) -> Entry? {
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        guard (try? FileManager.default.copyItem(at: sourceURL, to: destination)) != nil else { return nil }

        var entries = all().filter { $0.title != title }
        entries.insert(Entry(id: fileName, title: title, addedAt: Date()), at: 0)
        if entries.count > maxCount {
            for stale in entries[maxCount...] {
                try? FileManager.default.removeItem(at: stale.url)
            }
            entries = Array(entries.prefix(maxCount))
        }
        save(entries)
        return entries.first
    }

    static func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        save(all().filter { $0.id != entry.id })
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Müzik seçim ekranında dokununca çalıp duraklatan basit önizleme oynatıcı. Aynı anda
/// tek bir parça çalar; başka bir parçaya dokununca öncekini otomatik durdurur.
@MainActor
@Observable
final class SoundtrackPreviewPlayer: NSObject {
    private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
        } else {
            play(id: id, url: url)
        }
    }

    func play(id: String, url: URL, at offset: Double = 0) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0.9
        player.prepareToPlay()
        player.currentTime = max(0, min(offset, player.duration))
        player.play()
        self.player = player
        playingID = id
    }

    /// Çalarken başlangıç noktasını değiştirir (kullanıcı kaydırma çubuğunu sürüklerken).
    func seek(to offset: Double) {
        player?.currentTime = max(0, min(offset, player?.duration ?? 0))
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum SoundtrackTranscoder {

    static func aacFile(from url: URL) async -> URL {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let formats = try? await track.load(.formatDescriptions),
           let format = formats.first,
           CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC {
            return url
        }
        return await transcode(url) ?? url
    }

    static func transcode(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtrack-aac-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        do {
            try await export.export(to: output, as: .m4a)
            return output
        } catch {
            return nil
        }
    }
}

/// Şarkının vuruş (beat) anlarını bulur: bant bazlı spectral flux'tan onset zarfı
/// çıkarılır, özilintiyle tempo kestirilir ve dinamik programlamayla (Ellis beat
/// tracker) vuruşlar düzenli bir ızgara olarak izlenir.
enum AudioBeatAnalyzer {

    static func beats(in url: URL) async throws -> [Double] {
        try await Task.detached(priority: .userInitiated) {
            try await analyze(url)
        }.value
    }

    private static let sampleRate = 22050.0
    private static let hop = 512

    private static func analyze(_ url: URL) async throws -> [Double] {
        let hopDuration = Double(hop) / sampleRate
        let samples = try await decodeSamples(url)
        guard samples.count >= hop * 16 else { return [] }

        let envelope = onsetEnvelope(samples: samples)
        guard envelope.count > 32 else { return [] }
        let period = tempoPeriod(envelope: envelope, hopDuration: hopDuration)
        let beats = trackBeats(envelope: envelope, period: period, hopDuration: hopDuration)
        if beats.count >= 2 { return beats }

        let total = Double(envelope.count) * hopDuration
        return stride(from: period, through: total, by: period).map { $0 }
    }

    private static func decodeSamples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let count = length / MemoryLayout<Int16>.size
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { raw in
                samples.reserveCapacity(samples.count + count)
                for i in 0..<count { samples.append(Float(raw[i]) / 32768) }
            }
        }
        return samples
    }

    private static func onsetEnvelope(samples: [Float]) -> [Float] {
        let win = 1024
        let bins = win / 2
        guard samples.count >= win,
              let fft = vDSP.FFT(log2n: vDSP_Length(10), radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: win, isHalfWindow: false)

        let bandCount = 24
        let lowBin = 2
        let highBin = bins - 1
        let ratio = pow(Double(highBin) / Double(lowBin), 1.0 / Double(bandCount))
        var bandEdges: [Int] = [lowBin]
        for b in 1...bandCount {
            let edge = Int((Double(lowBin) * pow(ratio, Double(b))).rounded())
            bandEdges.append(max(edge, bandEdges[b - 1] + 1))
        }
        let binHz = sampleRate / Double(win)
        let bandWeights: [Float] = (0..<bandCount).map { b in
            Double(bandEdges[b + 1]) * binHz < 220 ? 2.0 : 1.0
        }

        var previous = [Float](repeating: 0, count: bandCount)
        var flux: [Float] = []
        var windowed = [Float](repeating: 0, count: win)
        var real = [Float](repeating: 0, count: bins)
        var imag = [Float](repeating: 0, count: bins)
        var outReal = [Float](repeating: 0, count: bins)
        var outImag = [Float](repeating: 0, count: bins)

        var frame = 0
        while frame + win <= samples.count {
            vDSP.multiply(samples[frame..<(frame + win)], window, result: &windowed)
            windowed.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complexPtr in
                    real.withUnsafeMutableBufferPointer { r in
                        imag.withUnsafeMutableBufferPointer { im in
                            outReal.withUnsafeMutableBufferPointer { outR in
                                outImag.withUnsafeMutableBufferPointer { outI in
                                    var input = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                                    var output = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                                    vDSP_ctoz(complexPtr, 2, &input, 1, vDSP_Length(bins))
                                    fft.forward(input: input, output: &output)
                                }
                            }
                        }
                    }
                }
            }
            var value: Float = 0
            for b in 0..<bandCount {
                var energy: Float = 0
                for k in bandEdges[b]..<min(bandEdges[b + 1], bins) {
                    energy += sqrt(outReal[k] * outReal[k] + outImag[k] * outImag[k])
                }
                let level = log1p(energy)
                let diff = level - previous[b]
                if diff > 0 { value += diff * bandWeights[b] }
                previous[b] = level
            }
            flux.append(value)
            frame += hop
        }
        guard flux.count > 8 else { return [] }

        let meanRadius = Int(0.5 * sampleRate / Double(hop))
        var detrended = [Float](repeating: 0, count: flux.count)
        for i in flux.indices {
            let lo = max(0, i - meanRadius)
            let hi = min(flux.count - 1, i + meanRadius)
            var mean: Float = 0
            flux.withUnsafeBufferPointer { buf in
                vDSP_meanv(buf.baseAddress! + lo, 1, &mean, vDSP_Length(hi - lo + 1))
            }
            detrended[i] = max(0, flux[i] - mean)
        }
        var mean: Float = 0
        var sd: Float = 0
        vDSP_normalize(detrended, 1, nil, 1, &mean, &sd, vDSP_Length(detrended.count))
        guard sd > 0 else { return [] }
        return vDSP.divide(detrended, sd)
    }

    private static func tempoPeriod(envelope: [Float], hopDuration: Double) -> Double {
        let minLag = max(2, Int((60.0 / 180.0) / hopDuration))
        let maxLag = min(envelope.count / 2, Int((60.0 / 60.0) / hopDuration))
        guard maxLag > minLag else { return 0.5 }

        func correlation(_ lag: Int) -> Double {
            guard lag >= 1, lag < envelope.count else { return 0 }
            var dot: Float = 0
            envelope.withUnsafeBufferPointer { buf in
                vDSP_dotpr(buf.baseAddress!, 1, buf.baseAddress! + lag, 1, &dot, vDSP_Length(envelope.count - lag))
            }
            return Double(dot) / Double(envelope.count - lag)
        }

        var scores: [(lag: Int, score: Double)] = []
        for lag in minLag...maxLag {
            let seconds = Double(lag) * hopDuration
            let weight = exp(-0.5 * pow(log2(seconds / 0.5), 2))
            scores.append((lag, (correlation(lag) + 0.5 * correlation(lag / 2)) * weight))
        }
        let smoothed = scores.indices.map { i -> (lag: Int, score: Double) in
            let lo = max(scores.startIndex, i - 1)
            let hi = min(scores.endIndex - 1, i + 1)
            return (scores[i].lag, scores[lo...hi].map(\.score).reduce(0, +))
        }
        guard let best = smoothed.map(\.score).max(), best > 0 else { return 0.5 }
        let chosen = smoothed.first { $0.score >= best * 0.9 }?.lag ?? minLag
        return Double(chosen) * hopDuration
    }

    private static func trackBeats(envelope: [Float], period: Double, hopDuration: Double) -> [Double] {
        let tau = period / hopDuration
        guard tau > 2 else { return [] }
        let tightness: Float = 100
        let n = envelope.count
        var score = [Float](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)
        let windowLo = Int((tau * 0.5).rounded())
        let windowHi = Int((tau * 2.0).rounded())

        for t in 0..<n {
            var best: Float = 0
            var bestPrev = -1
            let lo = max(0, t - windowHi)
            let hi = t - windowLo
            if hi >= 0 {
                for prev in lo...hi {
                    let interval = Float(t - prev)
                    let penalty = -tightness * pow(log(interval / Float(tau)), 2)
                    let candidate = score[prev] + penalty
                    if candidate > best {
                        best = candidate
                        bestPrev = prev
                    }
                }
            }
            score[t] = envelope[t] + best
            backlink[t] = bestPrev
        }

        let tailStart = max(0, n - Int(tau.rounded()))
        var cursor = tailStart
        for t in tailStart..<n where score[t] > score[cursor] { cursor = t }

        var indices: [Int] = []
        while cursor >= 0 {
            indices.append(cursor)
            cursor = backlink[cursor]
        }
        indices.reverse()
        guard indices.count >= 2 else { return [] }

        let beatScores = indices.map { envelope[$0] }
        let threshold = beatScores.reduce(0, +) / Float(beatScores.count) * 0.25
        var kept = Array(indices.drop { envelope[$0] < threshold })

        if period < 0.35, kept.count >= 4 {
            var phaseStrength: [Float] = [0, 0]
            for (position, index) in kept.enumerated() { phaseStrength[position % 2] += envelope[index] }
            let start = phaseStrength[0] >= phaseStrength[1] ? 0 : 1
            kept = stride(from: start, to: kept.count, by: 2).map { kept[$0] }
        }

        return kept.map { index in
            var refined = Double(index)
            if index > 0, index + 1 < envelope.count {
                let a = Double(envelope[index - 1])
                let b = Double(envelope[index])
                let c = Double(envelope[index + 1])
                let curvature = a - 2 * b + c
                if curvature < 0 {
                    refined += min(0.5, max(-0.5, 0.5 * (a - c) / curvature))
                }
            }
            return (refined + 1) * hopDuration
        }
    }
}

/// Render edilen sessiz videoya müziği ekler: parça video süresine göre döngülenir ya da
/// kırpılır, son 1.2 saniyede yumuşakça kısılır.
enum SoundtrackMuxer {

    static func fadeDuration(for videoDuration: Double) -> Double {
        min(1.2, max(0, videoDuration / 2))
    }

    static func mux(videoURL: URL, audioURL: URL, startOffset: Double = 0) async throws -> URL {
        try await mux(videoURL: videoURL, audioURL: audioURL, startOffset: startOffset, allowRetry: true)
    }

    private static func mux(videoURL: URL, audioURL: URL, startOffset: Double, allowRetry: Bool) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let composition = AVMutableComposition()
        guard
            let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TimelapseComposerError.writerFailed }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

        // Kullanıcı bir başlangıç noktası seçtiyse ilk tur oradan başlar; parça
        // sonuna ulaşınca sonraki turlar parçanın gerçek başından normal şekilde devam eder.
        let clampedOffset = max(0, min(startOffset, max(0, audioDuration.seconds - 0.1)))
        var sourcePosition = CMTime(seconds: clampedOffset, preferredTimescale: audioDuration.timescale)
        var cursor = CMTime.zero
        while cursor < videoDuration {
            let remainingVideo = videoDuration - cursor
            let remainingSource = audioDuration - sourcePosition
            let chunk = min(remainingVideo, remainingSource)
            guard chunk > .zero else { break }
            try compAudio.insertTimeRange(CMTimeRange(start: sourcePosition, duration: chunk), of: audioTrack, at: cursor)
            cursor = cursor + chunk
            sourcePosition = .zero
        }

        let mix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: compAudio)
        let fadeDuration = CMTime(
            seconds: fadeDuration(for: videoDuration.seconds),
            preferredTimescale: 600
        )
        let fadeStart = max(.zero, videoDuration - fadeDuration)
        parameters.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume: 1,
            timeRange: CMTimeRange(start: .zero, duration: fadeDuration)
        )
        parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration))
        mix.inputParameters = [parameters]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelapse-audio-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw TimelapseComposerError.writerFailed }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.audioMix = mix
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard allowRetry, let fallback = await SoundtrackTranscoder.transcode(audioURL) else { throw error }
            return try await mux(videoURL: videoURL, audioURL: fallback, startOffset: startOffset, allowRetry: false)
        }
        try? FileManager.default.removeItem(at: videoURL)
        return outputURL
    }
}
