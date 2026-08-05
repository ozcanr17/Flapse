#if DEBUG
import XCTest
@testable import Flapse

@MainActor
final class DebugProOverrideTests: XCTestCase {
    func test_debugOverrideTogglesAndUnlocksPro() {
        let store = StoreService()
        let initial = store.debugProOverrideActive

        let toggled = store.toggleDebugProOverride()

        XCTAssertEqual(toggled, !initial)
        XCTAssertEqual(store.debugProOverrideActive, !initial)
        if toggled {
            XCTAssertTrue(store.isPro)
        }

        let restored = store.toggleDebugProOverride()
        XCTAssertEqual(restored, initial)
    }
}
#endif
