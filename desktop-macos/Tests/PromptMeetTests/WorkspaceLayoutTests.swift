import CoreGraphics
import XCTest
@testable import PromptMeet

final class WorkspaceLayoutTests: XCTestCase {
    func testTimelineInitiallyFollowsAndRequestsScrollForContentChanges() {
        var state = TimelineFollowState()

        XCTAssertTrue(state.isFollowing)
        XCTAssertTrue(state.contentDidChange())
        XCTAssertTrue(state.isProgrammaticScroll)
    }

    func testRapidUpdatesDoNotDisableFollowBeforeProgrammaticScrollSettles() {
        var state = TimelineFollowState()

        XCTAssertTrue(state.contentDidChange())
        state.update(bottomDistance: 160)
        XCTAssertTrue(state.isFollowing)
        XCTAssertTrue(state.contentDidChange())

        state.update(bottomDistance: 0)
        XCTAssertFalse(state.isProgrammaticScroll)
        XCTAssertTrue(state.isFollowing)
    }

    func testManualScrollPositionIgnoresNewTimelineContent() {
        var state = TimelineFollowState()

        state.update(bottomDistance: 120)

        XCTAssertFalse(state.isFollowing)
        XCTAssertFalse(state.contentDidChange())
    }

    func testResumeAndReturningNearBottomRestoreFollow() {
        var state = TimelineFollowState()
        state.update(bottomDistance: 120)

        state.resume()
        XCTAssertTrue(state.isFollowing)
        XCTAssertTrue(state.isProgrammaticScroll)
        state.update(bottomDistance: 0)
        XCTAssertFalse(state.isProgrammaticScroll)

        state.update(bottomDistance: 90)
        XCTAssertFalse(state.isFollowing)
        state.update(bottomDistance: TimelineFollowState.bottomTolerance)
        XCTAssertTrue(state.isFollowing)
    }

    func testExplicitFollowControlCanPauseWithoutMovingScrollPosition() {
        var state = TimelineFollowState()

        state.pause()

        XCTAssertFalse(state.isFollowing)
        XCTAssertFalse(state.isProgrammaticScroll)
        XCTAssertFalse(state.contentDidChange())
    }

    func testFollowToggleRequestsImmediateScrollOnlyWhenResuming() {
        var state = TimelineFollowState()

        XCTAssertFalse(state.toggleFollow())
        XCTAssertFalse(state.isFollowing)

        XCTAssertTrue(state.toggleFollow())
        XCTAssertTrue(state.isFollowing)
        XCTAssertTrue(state.isProgrammaticScroll)
    }

    func testCompactWorkspaceColumnsFitWithAndWithoutHistory() {
        for showsHistory in [false, true] {
            let widths = WorkspaceLayout.columnWidths(totalWidth: 980, showsHistory: showsHistory)

            XCTAssertGreaterThanOrEqual(widths.timeline, WorkspaceLayout.minimumTimelineWidth)
            XCTAssertGreaterThanOrEqual(widths.intelligence, WorkspaceLayout.minimumIntelligenceWidth)
            XCTAssertLessThanOrEqual(widths.occupiedWidth, 980)
            XCTAssertGreaterThanOrEqual(widths.history, showsHistory ? WorkspaceLayout.historyWidth : 0)
        }
    }

    func testLargeWorkspaceAllocatesAdditionalReadingWidthWithoutClipping() {
        let widths = WorkspaceLayout.columnWidths(totalWidth: 1_440, showsHistory: true)

        XCTAssertGreaterThan(widths.timeline, WorkspaceLayout.minimumTimelineWidth)
        XCTAssertGreaterThan(widths.intelligence, WorkspaceLayout.minimumIntelligenceWidth)
        XCTAssertLessThanOrEqual(widths.occupiedWidth, 1_440)
        XCTAssertEqual(widths.history, WorkspaceLayout.historyWidth)
    }

    func testWorkspaceMinimumBoundsAndActionHitHeightAreExplicit() {
        XCTAssertEqual(WorkspaceLayout.minimumWindowSize, CGSize(width: 980, height: 640))
        XCTAssertGreaterThanOrEqual(WorkspaceLayout.actionHeight, 34)

        for size in [
            CGSize(width: 980, height: 640),
            CGSize(width: 1_440, height: 900)
        ] {
            let widths = WorkspaceLayout.columnWidths(totalWidth: size.width, showsHistory: true)
            XCTAssertGreaterThanOrEqual(size.height, WorkspaceLayout.minimumWindowSize.height)
            XCTAssertGreaterThanOrEqual(widths.remainingWidth, 0)
            XCTAssertLessThanOrEqual(widths.occupiedWidth, size.width)
        }
    }
}
