import Foundation
import XCTest
@testable import PromptMeet

final class MeetingAutomationSchedulerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testDefaultCadenceGeneratesAtFiveTenAndEveryFiveActiveMinutes() {
        var scheduler = MeetingAutomationScheduler(cadence: .fiveMinutes)
        scheduler.start(at: start)

        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(299), inputRevision: 1))
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(300), inputRevision: 1),
            .generate(.init(activeMinutes: 5, inputRevision: 1))
        )
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(600), inputRevision: 2),
            .generate(.init(activeMinutes: 10, inputRevision: 2))
        )
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(900), inputRevision: 3),
            .generate(.init(activeMinutes: 15, inputRevision: 3))
        )
    }

    func testThreeMinuteCadenceUsesThreeMinuteMilestones() {
        var scheduler = MeetingAutomationScheduler(cadence: .threeMinutes)
        scheduler.start(at: start)

        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(180), inputRevision: 1),
            .generate(.init(activeMinutes: 3, inputRevision: 1))
        )
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(360), inputRevision: 2),
            .generate(.init(activeMinutes: 6, inputRevision: 2))
        )
    }

    func testPausedWallTimeDoesNotCountTowardMilestone() {
        var scheduler = MeetingAutomationScheduler(cadence: .fiveMinutes)
        scheduler.start(at: start)
        scheduler.pause(at: start.addingTimeInterval(120))

        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(1_200), inputRevision: 1))
        scheduler.resume(at: start.addingTimeInterval(1_200))
        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(1_379), inputRevision: 1))
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(1_380), inputRevision: 1),
            .generate(.init(activeMinutes: 5, inputRevision: 1))
        )
    }

    func testNoNewInputProducesNoActionAndAdvancesMilestoneOnce() {
        var scheduler = MeetingAutomationScheduler(cadence: .fiveMinutes)
        scheduler.start(at: start)
        _ = scheduler.evaluate(at: start.addingTimeInterval(300), inputRevision: 1)

        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(600), inputRevision: 1),
            .noAction(.init(activeMinutes: 10, inputRevision: 1))
        )
        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(601), inputRevision: 2))
        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(900), inputRevision: 2),
            .generate(.init(activeMinutes: 15, inputRevision: 2))
        )
    }

    func testSuspendedClockSkipsMissedBurstAndFiresOnlyLatestCrossedMilestone() {
        var scheduler = MeetingAutomationScheduler(cadence: .fiveMinutes)
        scheduler.start(at: start)

        XCTAssertEqual(
            scheduler.evaluate(at: start.addingTimeInterval(16 * 60), inputRevision: 4),
            .generate(.init(activeMinutes: 15, inputRevision: 4))
        )
        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(16 * 60 + 1), inputRevision: 5))
    }

    func testOffCadenceNeverSchedules() {
        var scheduler = MeetingAutomationScheduler(cadence: .off)
        scheduler.start(at: start)

        XCTAssertNil(scheduler.evaluate(at: start.addingTimeInterval(3_600), inputRevision: 9))
    }
}
