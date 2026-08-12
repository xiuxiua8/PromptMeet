import AppKit
import XCTest
@testable import PromptMeet

final class IslandGeometryTests: XCTestCase {
    func testLiveIslandAddsCaptionHeightWithoutMovingControlRailEdges() {
        XCTAssertEqual(
            IslandGeometry.size(for: .live).width,
            IslandGeometry.size(for: .idle).width
        )
        XCTAssertGreaterThan(
            IslandGeometry.size(for: .live).height,
            IslandGeometry.size(for: .idle).height
        )
    }

    func testLiveIslandAddsOneCompactTickerRow() {
        let live = IslandGeometry.size(
            for: .live,
            topChromeWidth: 184,
            topChromeHeight: 32
        )

        XCTAssertEqual(live.width, 460)
        XCTAssertEqual(live.height, 54)
    }

    func testIslandUsesDetectedTopChromeHeight() {
        XCTAssertEqual(
            IslandGeometry.size(for: .idle, topChromeHeight: 32).height,
            32
        )
    }

    func testShortMenuBarStillKeepsCompleteButtonHitRegionsVisible() {
        let host = CGSize(width: 1_440, height: 640)
        let visible = IslandGeometry.visibleRect(
            for: .idle,
            inHost: host,
            topChromeWidth: 100,
            topChromeHeight: 24
        )
        let controls = IslandGeometry.controlHitRects(inHost: host, topChromeHeight: 24)

        XCTAssertEqual(visible.height, IslandGeometry.controlHitSize)
        XCTAssertTrue(visible.contains(controls.workspace))
        XCTAssertTrue(visible.contains(controls.pauseResume))
        XCTAssertTrue(visible.contains(controls.quickAsk))
    }

    func testAuraIdleIslandLeavesBalancedFlanksAroundThePhysicalNotch() {
        let size = IslandGeometry.size(
            for: .idle,
            topChromeWidth: 184,
            topChromeHeight: 32
        )

        XCTAssertEqual(size.width, IslandGeometry.controlRailWidth)
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

    func testControlAnchorsStayFixedAcrossCompactHoverAndQuickAskPresentations() {
        let host = CGSize(width: 1_440, height: 640)
        let presentations: [IslandPresentation] = [
            .idle, .connecting, .live, .answering, .hoverIdle, .hoverLive,
            .live, .hoverLive, .live, .hoverLive
        ]
        let expected = IslandGeometry.controlAnchors(inHost: host, topChromeHeight: 32)

        for presentation in presentations {
            XCTAssertEqual(
                IslandGeometry.controlAnchors(
                    for: presentation,
                    inHost: host,
                    topChromeHeight: 32
                ),
                expected
            )
        }
    }

    func testControlHitRegionsAreStableAndInsideEveryInteractiveRect() {
        for host in [
            CGSize(width: 640, height: 480),
            CGSize(width: 1_184, height: 640),
            CGSize(width: 1_440, height: 640),
            CGSize(width: 1_920, height: 1_080)
        ] {
            let expectedRects = IslandGeometry.controlHitRects(inHost: host, topChromeHeight: 32)
            for presentation in [
                IslandPresentation.idle, .connecting, .live, .answering, .hoverIdle, .hoverLive
            ] {
                let interactive = IslandGeometry.interactiveRect(
                    for: presentation,
                    inHost: host,
                    topChromeWidth: 184,
                    topChromeHeight: 32
                )
                let rects = IslandGeometry.controlHitRects(
                    for: presentation,
                    inHost: host,
                    topChromeHeight: 32
                )

                XCTAssertEqual(rects, expectedRects)
                XCTAssertEqual(rects.workspace.size, CGSize(width: 32, height: 32))
                XCTAssertEqual(rects.pauseResume.size, CGSize(width: 32, height: 32))
                XCTAssertEqual(rects.quickAsk.size, CGSize(width: 32, height: 32))
                XCTAssertTrue(interactive.contains(rects.workspace))
                XCTAssertTrue(interactive.contains(rects.pauseResume))
                XCTAssertTrue(interactive.contains(rects.quickAsk))
            }
        }
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

    func testSubtitleFlowAdvancesAtAdaptiveSpeed() {
        var flow = SubtitleStreamFlow()
        flow.append(
            SubtitleStreamPage(
                id: UUID(),
                text: "字幕内容",
                translation: nil,
                timestamp: nil,
                width: 420
            )
        )

        flow.tick(deltaTime: 1)

        XCTAssertEqual(
            flow.cursor,
            SubtitleFlowMetrics.speed(
                entryRatePtsPerSecond: flow.entryRatePtsPerSecond,
                pendingWidth: flow.pendingWidth
            ),
            accuracy: 0.001
        )
    }

    func testSubtitleFlowSpeedStaysWithinReadableBounds() {
        let quiet = SubtitleFlowMetrics.speed(entryRatePtsPerSecond: 0, pendingWidth: 0)
        let burst = SubtitleFlowMetrics.speed(entryRatePtsPerSecond: 5_000, pendingWidth: 10_000)

        XCTAssertEqual(quiet, SubtitleFlowMetrics.baseSpeed, accuracy: 0.001)
        XCTAssertEqual(burst, SubtitleFlowMetrics.maximumSpeed, accuracy: 0.001)
        XCTAssertLessThan(SubtitleFlowMetrics.baseSpeed, SubtitleFlowMetrics.maximumSpeed)
    }

    func testSubtitleFlowVisibleWindowShowsOnlyPagesUnderViewport() {
        var flow = SubtitleStreamFlow()
        flow.append(
            SubtitleStreamPage(
                id: UUID(),
                text: "first",
                translation: nil,
                timestamp: nil,
                width: 420
            )
        )
        flow.append(
            SubtitleStreamPage(
                id: UUID(),
                text: "second",
                translation: nil,
                timestamp: nil,
                width: 420
            )
        )

        let visible = flow.visiblePages(viewportWidth: 220)

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.page.text, "first")
    }
}
