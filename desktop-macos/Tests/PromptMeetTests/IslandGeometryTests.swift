import AppKit
import XCTest
@testable import PromptMeet

final class IslandGeometryTests: XCTestCase {
    func testLiveIslandMakesRoomForStreamingCaption() {
        XCTAssertGreaterThan(
            IslandGeometry.size(for: .live).width,
            IslandGeometry.size(for: .idle).width
        )
    }

    func testLiveIslandGrowsToWrapAStableTwoLineCaption() {
        let live = IslandGeometry.size(
            for: .live,
            topChromeWidth: 184,
            topChromeHeight: 32
        )

        XCTAssertEqual(live.width, 520)
        XCTAssertEqual(live.height, 82)
    }

    func testIslandUsesDetectedTopChromeHeight() {
        XCTAssertEqual(
            IslandGeometry.size(for: .idle, topChromeHeight: 32).height,
            32
        )
    }

    func testAuraIdleIslandLeavesBalancedFlanksAroundThePhysicalNotch() {
        let size = IslandGeometry.size(
            for: .idle,
            topChromeWidth: 184,
            topChromeHeight: 32
        )

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 32)
    }

    func testAuraHoverCardUsesTheApprovedBreathingRoom() {
        let size = IslandGeometry.size(for: .hoverLive)
        XCTAssertEqual(size.width, 760)
        XCTAssertEqual(size.height, 300)
        XCTAssertGreaterThan(size.width / size.height, 2.5)
    }

    func testIslandConnectsDirectlyToPhysicalScreenTopEdge() {
        let screen = CGRect(x: 100, y: 50, width: 1_440, height: 900)
        let frame = IslandGeometry.frame(for: .live, in: screen)

        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(IslandGeometry.topInset, 0)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    }

    func testSilhouetteUsesReferenceTopCurlInsteadOfFourRoundedCorners() {
        XCTAssertEqual(IslandShape.topCurl, 6)
    }

    func testHoverMorphKeepsAStableHostWindow() {
        XCTAssertEqual(IslandGeometry.hostSize, CGSize(width: 1_440, height: 640))

        let compact = IslandGeometry.visibleRect(for: .idle, inHost: IslandGeometry.hostSize)
        let expanded = IslandGeometry.visibleRect(for: .hoverIdle, inHost: IslandGeometry.hostSize)
        let triggerPoint = CGPoint(x: compact.midX, y: compact.midY)

        XCTAssertTrue(expanded.contains(triggerPoint))
    }

    func testInteractiveRectExactlyMatchesVisibleRectAtRealisticHostSizes() {
        for host in [
            CGSize(width: 1_184, height: 640),
            CGSize(width: 1_440, height: 640),
            CGSize(width: 1_920, height: 1_080)
        ] {
            for presentation in [IslandPresentation.idle, .live, .hoverIdle, .hoverLive] {
                XCTAssertEqual(
                    IslandGeometry.interactiveRect(
                        for: presentation,
                        inHost: host,
                        topChromeWidth: 184,
                        topChromeHeight: 32
                    ),
                    IslandGeometry.visibleRect(
                        for: presentation,
                        inHost: host,
                        topChromeWidth: 184,
                        topChromeHeight: 32
                    )
                )
            }
        }
    }

    func testLargeExpandedIslandControlsRemainInsideInteractiveRect() {
        let host = CGSize(width: 1_184, height: 640)
        let interactive = IslandGeometry.interactiveRect(
            for: .hoverLive,
            inHost: host,
            topChromeWidth: 184,
            topChromeHeight: 32
        )

        XCTAssertTrue(interactive.contains(CGPoint(x: interactive.maxX - 18, y: interactive.maxY - 18)))
        XCTAssertTrue(interactive.contains(CGPoint(x: interactive.minX + 18, y: interactive.minY + 18)))
    }

    func testHoverModeKeepsIdleCardCompact() {
        XCTAssertEqual(
            IslandGeometry.size(for: .hoverIdle),
            IslandGeometry.size(for: .hoverLive)
        )
    }

    func testMeetingStateSelectsPresentationWithoutReplacingTranscript() {
        var state = MeetingState.previewLive
        XCTAssertEqual(state.islandPresentation(isHovered: false), .live)
        XCTAssertEqual(state.islandPresentation(isHovered: true), .hoverLive)

        let requestID = UUID()
        state.reduce(.userPromptSubmitted(id: requestID, prompt: "总结"))
        state.reduce(.answerDelta(requestID: requestID, delta: "正在整理"))

        XCTAssertEqual(state.islandPresentation(isHovered: false), .answering)
        XCTAssertEqual(state.activeCaption, "我们先确认今天的讨论目标。")
    }
}
