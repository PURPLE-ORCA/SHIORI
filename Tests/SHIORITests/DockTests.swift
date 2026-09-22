import XCTest
@testable import SHIORI

final class DockTests: XCTestCase {
    func testHoverStateTransitionsCancelStaleOpenAndClose() {
        var state = DockStateMachine()
        XCTAssertEqual(state.phase, .collapsed)

        state.pointerEntered()
        XCTAssertEqual(state.phase, .pendingOpen)
        state.pointerExited()
        XCTAssertEqual(state.phase, .collapsed)
        state.openDelayElapsed()
        XCTAssertEqual(state.phase, .collapsed)

        state.pointerEntered()
        state.openDelayElapsed()
        XCTAssertEqual(state.phase, .expanded)
        state.pointerExited()
        XCTAssertEqual(state.phase, .pendingClose)
        state.pointerEntered()
        XCTAssertEqual(state.phase, .expanded)
        state.closeDelayElapsed()
        XCTAssertEqual(state.phase, .expanded)
    }

    func testExplicitShowAndHideAreIdempotent() {
        var state = DockStateMachine()
        state.showImmediately()
        state.showImmediately()
        XCTAssertEqual(state.phase, .expanded)
        state.hideImmediately()
        state.hideImmediately()
        XCTAssertEqual(state.phase, .collapsed)
    }
}
