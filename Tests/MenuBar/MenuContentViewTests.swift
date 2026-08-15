import XCTest
@testable import Viska

@MainActor
final class MenuContentViewTests: XCTestCase {
    func testContentSizeStopsGrowingAfterVisibleHistoryLimit() {
        XCTAssertEqual(
            MenuContentView.contentSize(forHistoryCount: 4),
            MenuContentView.contentSize(forHistoryCount: 10)
        )
    }

    func testContentSizeAccountsForStatusAndHotkeyMessages() {
        let baseSize = MenuContentView.contentSize(forHistoryCount: 4)
        let messageSize = MenuContentView.contentSize(
            forHistoryCount: 4,
            showsStatusDetail: true,
            showsHotkeyError: true
        )

        XCTAssertEqual(messageSize.height, baseSize.height + 56)
    }
}
