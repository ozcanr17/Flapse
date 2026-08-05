import XCTest
import AVFoundation
import SwiftUI
import UIKit
@testable import Flapse

final class TimelapseComposerTests: XCTestCase {

    private func frameData(_ index: Int) -> Data {
        let size = CGSize(width: 120, height: 160)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(hue: CGFloat(index % 10) / 10, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func frame(_ index: Int) -> TimelapseFrame {
        TimelapseFrame(imageData: frameData(index), capturedAt: Date(timeIntervalSince1970: Double(index)))
    }

    func test_videoDosyasiOlusur_veSuresiKareSayisinaUyar() async throws {
        let frames = (0..<8).map(frame)
        let settings = TimelapseExportSettings(
            renderSize: CGSize(width: 240, height: 320),
            framesPerSecond: 8,
            includesWatermark: true
        )

        let url = try await TimelapseComposer().makeVideo(from: frames, settings: settings, onProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, 4.0, accuracy: 0.4)
    }

    func test_kaydedilenVideo_icinThumbnailUretilir() async throws {
        let url = try await TimelapseComposer().makeVideo(
            from: (0..<3).map(frame),
            settings: TimelapseExportSettings(
                renderSize: CGSize(width: 240, height: 320),
                framesPerSecond: 4,
                includesWatermark: false
            ),
            onProgress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let posterData = await TimelapseLibrary.makePosterData(videoURL: url)

        XCTAssertNotNil(posterData)
        XCTAssertNotNil(posterData.flatMap(UIImage.init(data:)))
    }

    func test_yumusakGecis_yuksekCozunurlukte_videoUretir() async throws {
        let frames = (0..<8).map(frame)
        let settings = TimelapseExportSettings(
            renderSize: CGSize(width: 2160, height: 2880),
            framesPerSecond: 8,
            includesWatermark: false,
            transition: .smooth
        )

        let url = try await TimelapseComposer().makeVideo(from: frames, settings: settings, onProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, 4.0, accuracy: 0.4)
    }

    func test_ikidenAzKare_hataVerir() async {
        do {
            _ = try await TimelapseComposer().makeVideo(
                from: [frame(0)],
                settings: .current(isPro: false),
                onProgress: { _ in }
            )
            XCTFail("notEnoughFrames hatası bekleniyordu")
        } catch {
            XCTAssertEqual(error as? TimelapseComposerError, .notEnoughFrames)
        }
    }

    func test_bozukKareVerisi_hataVerir() async {
        do {
            _ = try await TimelapseComposer().makeVideo(
                from: [
                    TimelapseFrame(imageData: Data([0x00]), capturedAt: Date(timeIntervalSince1970: 0)),
                    TimelapseFrame(imageData: Data([0x01]), capturedAt: Date(timeIntervalSince1970: 1))
                ],
                settings: .current(isPro: false),
                onProgress: { _ in }
            )
            XCTFail("frameDecodingFailed hatası bekleniyordu")
        } catch {
            XCTAssertEqual(error as? TimelapseComposerError, .frameDecodingFailed)
        }
    }
    func test_zoomKucultunce_siyahBantYerineBulanikZeminCizilir() async throws {
        let frames = (0..<3).map(frame)
        let settings = TimelapseExportSettings.current(isPro: false, zoom: 0.5)

        let url = try await TimelapseComposer().makeVideo(from: frames, settings: settings, onProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cgImage = try await generator.image(at: CMTime(value: 1, timescale: 30)).image

        let corner = try XCTUnwrap(pixel(in: cgImage, x: 4, y: 4))
        let brightness = max(corner.r, corner.g, corner.b)
        XCTAssertGreaterThan(brightness, 0.1, "Köşe simsiyah — bulanık zemin çizilmemiş")
    }

    func test_outroZemini_sonKareninBulanigi_siyahDegil() async throws {
        let frames = (0..<3).map(frame)
        let settings = TimelapseExportSettings.current(isPro: false)

        let url = try await TimelapseComposer().makeVideo(from: frames, settings: settings, onProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: duration.seconds - 0.2, preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image

        let corner = try XCTUnwrap(pixel(in: cgImage, x: 4, y: 4))
        let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "") ?? .filmNegative
        let canvas = UIColor(theme.palette.canvas).resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        canvas.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(corner.r, r, accuracy: 0.12, "Outro zemini tema renginde değil")
        XCTAssertEqual(corner.g, g, accuracy: 0.12)
        XCTAssertEqual(corner.b, b, accuracy: 0.12)
    }

    func test_flowMorph_araKareUretir() throws {
        func square(at x: CGFloat) -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320), format: format).image { _ in
                UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 240, height: 320))
                UIColor.white.setFill(); UIRectFill(CGRect(x: x, y: 130, width: 60, height: 60))
            }.cgImage!
        }
        let frames = FlowMorpher.morphFrames(
            from: square(at: 40), to: square(at: 140),
            steps: 3, canvas: CGSize(width: 240, height: 320)
        )
        let produced = try XCTUnwrap(frames)
        XCTAssertEqual(produced.count, 3)

        let mid = produced[1]
        let midPixel = try XCTUnwrap(pixel(in: mid, x: 120, y: 160))
        XCTAssertGreaterThan(midPixel.r, 0.15, "Orta karede kare ara konumda değil — morph çalışmıyor")
    }

    func testCoupleLandscapeFrameFitsInsidePortraitCanvas() {
        let rect = TimelapseFrameLayout.aspectFitRect(
            for: CGSize(width: 1600, height: 900),
            canvas: CGSize(width: 900, height: 1600)
        )

        XCTAssertEqual(rect.width, 900, accuracy: 0.001)
        XCTAssertEqual(rect.height, 506.25, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 450, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 800, accuracy: 0.001)
    }

    func testCouplePortraitFrameFitsInsideLandscapeCanvas() {
        let rect = TimelapseFrameLayout.aspectFitRect(
            for: CGSize(width: 900, height: 1600),
            canvas: CGSize(width: 1600, height: 900)
        )

        XCTAssertEqual(rect.width, 506.25, accuracy: 0.001)
        XCTAssertEqual(rect.height, 900, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 800, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 450, accuracy: 0.001)
        XCTAssertEqual(TimelapseFrameLayout.losslessZoom(0.75), 0.75)
        XCTAssertEqual(TimelapseFrameLayout.losslessZoom(2), 1)
    }

    private func pixel(in image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bpp
        guard offset + 2 < data.count else { return nil }
        return (CGFloat(data[offset]) / 255, CGFloat(data[offset + 1]) / 255, CGFloat(data[offset + 2]) / 255)
    }
}

final class TimelapseExportSettingsTests: XCTestCase {

    func test_proAyarlari_yuksekCozunurlukVeFiligransiz() {
        let settings = TimelapseExportSettings.current(isPro: true)

        XCTAssertEqual(settings.renderSize, CGSize(width: 2160, height: 2880))
        XCTAssertFalse(settings.includesWatermark)
    }

    func test_ucretsizAyarlar_dusukCozunurlukVeFiligranli() {
        let settings = TimelapseExportSettings.current(isPro: false)

        XCTAssertEqual(settings.renderSize, CGSize(width: 720, height: 960))
        XCTAssertTrue(settings.includesWatermark)
    }

    func test_varsayilanHiz_normaldirVe4fpsdir() {
        XCTAssertEqual(TimelapseExportSettings.current(isPro: false).framesPerSecond, 4)
        XCTAssertEqual(TimelapseExportSettings.current(isPro: true).framesPerSecond, 4)
    }

    func test_hizSeciminiKareHizinaUygular() {
        XCTAssertEqual(TimelapseExportSettings.current(isPro: false, speed: .quarter).framesPerSecond, 1)
        XCTAssertEqual(TimelapseExportSettings.current(isPro: false, speed: .slow).framesPerSecond, 2)
        XCTAssertEqual(TimelapseExportSettings.current(isPro: true, speed: .fast).framesPerSecond, 8)
        XCTAssertEqual(TimelapseExportSettings.current(isPro: true, speed: .turbo).framesPerSecond, 12)
    }

    func test_besHizSecenegiVar() {
        XCTAssertEqual(TimelapseSpeed.allCases.count, 5)
        XCTAssertEqual(TimelapseSpeed.allCases.map(\.displayName),
                       ["0.25×", "0.5×", "1×", "2×", "3×"])
    }

    func test_akilliHizalama_varsayilanKapali_ayarlaAcilir() {
        XCTAssertFalse(TimelapseExportSettings.current(isPro: true).smartAlignment)
        XCTAssertTrue(TimelapseExportSettings.current(isPro: true, smartAlignment: true).smartAlignment)
    }

    func test_hizDegisikligi_cozunurlukVeFiligraniEtkilemez() {
        let free = TimelapseExportSettings.current(isPro: false, speed: .turbo)
        XCTAssertEqual(free.renderSize, CGSize(width: 720, height: 960))
        XCTAssertTrue(free.includesWatermark)
    }
}
