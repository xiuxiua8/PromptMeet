import CoreGraphics
import Foundation
import XCTest
@testable import PromptMeet

final class SubtitleFlowSpeedTests: XCTestCase {

    private func page(_ text: String, width: CGFloat = 200) -> SubtitleStreamPage {
        SubtitleStreamPage(id: UUID(), text: text, timestamp: Date(), width: width)
    }

    func testFreshlyGeneratedCaptionFlowsAtItsEntryRate() {
        var flow = SubtitleStreamFlow()
        flow.append(page("single quiet caption", width: 300))
        let expectedRate = 300 / CGFloat(SubtitleFlowMetrics.rateWindow)
        let targetSpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: expectedRate,
            pendingWidth: flow.pendingWidth
        )

        // Let the smoothing settle toward the target (several seconds).
        for _ in 0..<40 {
            flow.tick(deltaTime: 0.1)
        }

        XCTAssertEqual(flow.entryRatePtsPerSecond, expectedRate, accuracy: 0.001)
        XCTAssertEqual(flow.currentSpeed, targetSpeed, accuracy: targetSpeed * 0.05)
        XCTAssertGreaterThan(targetSpeed, SubtitleFlowMetrics.baseSpeed)
    }

    func testSmoothingRampsSpeedGraduallyInsteadOfJumping() {
        var flow = SubtitleStreamFlow()
        flow.append(page("burst start", width: 100))
        for _ in 0..<10 {
            flow.append(page("burst continuation", width: 400))
        }
        let targetSpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: flow.entryRatePtsPerSecond,
            pendingWidth: flow.pendingWidth
        )
        XCTAssertGreaterThan(targetSpeed, SubtitleFlowMetrics.maximumSpeed * 0.9)

        // One frame after the burst: the applied speed is far below the target.
        flow.tick(deltaTime: 0.05)
        XCTAssertLessThan(flow.currentSpeed, targetSpeed * 0.3)

        // It approaches the target gradually, never overshooting it.
        var previous: CGFloat = 0
        for _ in 0..<60 {
            flow.tick(deltaTime: 0.1)
            XCTAssertLessThanOrEqual(flow.currentSpeed, targetSpeed + 0.001)
            XCTAssertGreaterThanOrEqual(flow.currentSpeed, previous - 0.001)
            previous = flow.currentSpeed
        }
        XCTAssertEqual(flow.currentSpeed, targetSpeed, accuracy: targetSpeed * 0.05)
    }

    // MARK: - Early/late balance contract (雨露均沾)

    func testLateBacklogPhaseStaysReadable() {
        var flow = SubtitleStreamFlow()
        for index in 0..<12 {
            flow.append(page("deep backlog line \(index)", width: 400))
        }
        let targetSpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: flow.entryRatePtsPerSecond,
            pendingWidth: flow.pendingWidth
        )

        // The deep backlog must never push the flow past the readable cap,
        // and the drain contribution is bounded on top of the rate tracking.
        XCTAssertLessThanOrEqual(targetSpeed, SubtitleFlowMetrics.maximumSpeed)
        XCTAssertLessThanOrEqual(
            targetSpeed,
            SubtitleFlowMetrics.baseSpeed
                + SubtitleFlowMetrics.keepUpGain * flow.entryRatePtsPerSecond
                + SubtitleFlowMetrics.maximumDrainBoost
                + 0.001
        )
    }

    func testEarlyAndLatePhaseSpeedsAreBalanced() {
        // Early phase: one fresh caption.
        var early = SubtitleStreamFlow()
        early.append(page("early caption", width: 500))
        let earlySpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: early.entryRatePtsPerSecond,
            pendingWidth: early.pendingWidth
        )

        // Late phase: a deep backlog of the same generation rate.
        var late = SubtitleStreamFlow()
        late.append(page("late caption", width: 500))
        for index in 0..<12 {
            late.append(page("late backlog line \(index)", width: 500))
        }
        let lateSpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: late.entryRatePtsPerSecond,
            pendingWidth: late.pendingWidth
        )

        // The late phase can only exceed the early phase by the bounded drain
        // boost - the two phases never diverge into unreadable speeds.
        XCTAssertLessThanOrEqual(
            lateSpeed - earlySpeed,
            SubtitleFlowMetrics.maximumDrainBoost + 0.001
        )
        XCTAssertLessThanOrEqual(lateSpeed, SubtitleFlowMetrics.maximumSpeed)
    }

    func testDrainBoostIsBoundedRegardlessOfBacklogDepth() {
        let target = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: 0,
            pendingWidth: 100_000
        )

        XCTAssertEqual(
            target,
            SubtitleFlowMetrics.baseSpeed + SubtitleFlowMetrics.maximumDrainBoost,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(target, SubtitleFlowMetrics.maximumSpeed)
    }

    func testDeepBacklogNeverRacesEvenWithSustainedGeneration() {
        var flow = SubtitleStreamFlow()
        for index in 0..<12 {
            flow.append(page("backlog line \(index)", width: 400))
        }

        // Simulate continued generation on top of the backlog.
        for segment in 0..<8 {
            flow.append(page("segment \(segment)", width: 400))
            for _ in 0..<40 {
                flow.tick(deltaTime: 0.1)
            }
            XCTAssertLessThanOrEqual(
                flow.currentSpeed,
                SubtitleFlowMetrics.maximumSpeed + 0.001,
                "speed must stay readable even with a deep backlog"
            )
        }
    }

    func testSpeedFallsBackToBasePaceWhenGenerationStops() {
        // With no measured generation, the metrics floor at the base pace.
        XCTAssertEqual(
            SubtitleFlowMetrics.speed(entryRatePtsPerSecond: 0, pendingWidth: 0),
            SubtitleFlowMetrics.baseSpeed,
            accuracy: 0.001
        )
    }

    func testSpeedTracksGenerationRate() {
        // One 360 pt page per 8 s segment = 45 pts/s of generation.
        var flow = SubtitleStreamFlow()
        flow.append(page("segment one", width: 360))
        flow.tick(deltaTime: 0.01)
        let expectedRate = 360 / CGFloat(SubtitleFlowMetrics.rateWindow)
        let expectedSpeed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: expectedRate,
            pendingWidth: flow.pendingWidth
        )

        XCTAssertEqual(flow.entryRatePtsPerSecond, expectedRate, accuracy: 0.5)
        XCTAssertGreaterThan(
            expectedSpeed,
            SubtitleFlowMetrics.baseSpeed,
            "the flow must outrun generation so the backlog cannot grow"
        )
        XCTAssertGreaterThanOrEqual(
            expectedSpeed,
            expectedRate * SubtitleFlowMetrics.keepUpGain
        )
    }

    func testSpeedIsMonotonicInGenerationRateAndClamped() {
        var previous: CGFloat = -1
        for rate in stride(from: 0, through: 500, by: 25) {
            let speed = SubtitleFlowMetrics.speed(
                entryRatePtsPerSecond: CGFloat(rate),
                pendingWidth: 0
            )
            XCTAssertGreaterThanOrEqual(speed, previous)
            previous = speed
        }
        XCTAssertEqual(
            SubtitleFlowMetrics.speed(entryRatePtsPerSecond: 10_000, pendingWidth: 0),
            SubtitleFlowMetrics.maximumSpeed,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SubtitleFlowMetrics.speed(entryRatePtsPerSecond: 0, pendingWidth: 0),
            SubtitleFlowMetrics.baseSpeed,
            accuracy: 0.001
        )
    }

    func testBurstAdvancesFasterThanQuietStream() {
        var quiet = SubtitleStreamFlow()
        quiet.append(page("Q1", width: 300))

        var burst = SubtitleStreamFlow()
        for index in 0..<8 {
            burst.append(page("burst line number \(index)", width: 260))
        }

        quiet.tick(deltaTime: 1)
        burst.tick(deltaTime: 1)

        XCTAssertGreaterThan(burst.cursor, quiet.cursor)
    }

    func testSpeedDecaysAsGenerationStops() {
        var flow = SubtitleStreamFlow()
        for index in 0..<6 {
            flow.append(page("line \(index)", width: 250))
        }
        flow.tick(deltaTime: 0.1)
        let fastCursor = flow.cursor
        // The pages drain at the elevated pace first; the tail finishes at a
        // readable pace as the generation window ages out.
        for _ in 0..<600 {
            flow.tick(deltaTime: 0.1)
        }
        XCTAssertTrue(flow.isEmpty)
        XCTAssertEqual(flow.entryRatePtsPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(flow.currentSpeed, SubtitleFlowMetrics.baseSpeed, accuracy: 1)

        flow.append(page("fresh", width: 250))
        flow.tick(deltaTime: 0.1)
        XCTAssertLessThan(flow.cursor, fastCursor)
    }

    // MARK: - No-backlog contract

    func testSustainedGenerationKeepsBacklogBounded() {
        // Simulate a busy meeting: one 360 pt segment (plus a 200 pt
        // translation-equivalent width) every 8 seconds for a minute.
        var flow = SubtitleStreamFlow()
        var peakPending: CGFloat = 0
        for segment in 0..<8 {
            flow.append(page("segment number \(segment)", width: 560))
            // The segment transcribes over its 8 s window.
            flow.tick(deltaTime: 8)
            peakPending = max(peakPending, flow.pendingWidth)
        }

        // The flow keeps up with generation: the backlog never grows beyond a
        // small constant (a fraction of one segment), instead of accumulating.
        XCTAssertLessThan(
            flow.pendingWidth,
            560 + SubtitleFlowMetrics.traverseGap,
            "backlog must not accumulate under sustained generation"
        )
        XCTAssertLessThan(peakPending, 2 * 560 + 2 * SubtitleFlowMetrics.traverseGap)
    }

    func testBurstBacklogDrainsAfterBurstEnds() {
        var flow = SubtitleStreamFlow()
        for index in 0..<10 {
            flow.append(page("burst line \(index)", width: 200))
        }
        XCTAssertGreaterThan(flow.pendingWidth, 1_000)

        // No further generation: the elevated rate + drain gain clears it.
        // The tail drains at a readable pace as the window ages out.
        for _ in 0..<80 {
            flow.tick(deltaTime: 0.5)
        }

        XCTAssertTrue(flow.isEmpty)
    }
}
