import XCTest
@testable import Flapse

/// Video kategorisi ve video Entry'lerinin saf mantığını test ediyoruz.
final class VideoModeTests: XCTestCase {

    func test_videoKategorisi_isVideoModeTrue() {
        XCTAssertTrue(ProjectCategory.video.isVideoMode)
    }

    func test_digerKategoriler_isVideoModeFalse() {
        for category in ProjectCategory.allCases where category != .video {
            XCTAssertFalse(category.isVideoMode, "\(category) video modu olmamalı")
        }
    }

    func test_videoFileNameOlanEntry_isVideoTrue() {
        let entry = Entry(videoFileName: "abc.mp4", videoDuration: 4.2)
        XCTAssertTrue(entry.isVideo)
        XCTAssertEqual(entry.videoDuration, 4.2)
    }

    func test_videoFileNameOlmayanEntry_isVideoFalse() {
        let entry = Entry(imageData: Data([0x01]))
        XCTAssertFalse(entry.isVideo)
    }
}
