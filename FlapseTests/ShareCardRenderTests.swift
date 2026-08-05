import SwiftUI
import XCTest
@testable import Flapse

@MainActor
final class ShareCardRenderTests: XCTestCase {
    private let theme = AppTheme.coastal.palette

    func test_streakCardRendersAtSocialPostSize() throws {
        let card = StreakShareCard(
            title: "Birlikte",
            categoryName: "Çift Modu",
            heroImage: image(color: .systemTeal),
            streak: 51,
            total: 128,
            daysRunning: 365,
            theme: theme
        )

        let rendered = try XCTUnwrap(ImageRenderer(content: card).uiImage)

        XCTAssertEqual(rendered.size, CGSize(width: 1_080, height: 1_350))
    }

    func test_compareCardRendersAtSocialPostSize() throws {
        let card = CompareShareCard(
            title: "Değişim",
            firstImage: image(color: .systemOrange),
            lastImage: image(color: .systemBlue),
            firstDate: .now.addingTimeInterval(-864_000),
            lastDate: .now,
            theme: theme
        )

        let rendered = try XCTUnwrap(ImageRenderer(content: card).uiImage)

        XCTAssertEqual(rendered.size, CGSize(width: 1_080, height: 1_350))
    }

    func test_storyCardRendersAtStorySize() throws {
        let card = StoryShareCard(
            title: "Büyürken",
            firstImage: image(color: .systemPink),
            lastImage: image(color: .systemPurple),
            firstDate: .now.addingTimeInterval(-864_000),
            lastDate: .now,
            theme: theme
        )

        let rendered = try XCTUnwrap(ImageRenderer(content: card).uiImage)

        XCTAssertEqual(rendered.size, CGSize(width: 1_080, height: 1_920))
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        }
    }
}
