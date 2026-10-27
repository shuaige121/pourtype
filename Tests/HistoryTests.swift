import SwiftUI
import XCTest
@testable import Pourtype

/// The history window's keys, deletion and retention.
final class HistoryTests: XCTestCase {
    /// Return ends a search in the sidebar; it must not also type the selected entry into another app.
    func testReturnDoesNotTypeAgain() {
        let s = HistoryView.typeAgainShortcut
        XCTAssertNotEqual(s, .defaultAction)
        XCTAssertEqual(s.key, .return)
        XCTAssertTrue(s.modifiers.contains(.command))
    }
}
