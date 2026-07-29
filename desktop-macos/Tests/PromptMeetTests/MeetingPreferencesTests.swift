import Foundation
import XCTest

@testable import PromptMeet

final class MeetingPreferencesTests: XCTestCase {
    func testCadenceAndMicrophonePreferencePersistAcrossInstances() throws {
        let suiteName = "MeetingPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MeetingPreferences(defaults: defaults)

        XCTAssertEqual(preferences.summaryCadence, .fiveMinutes)
        XCTAssertTrue(preferences.includeLocalMicrophone)

        preferences.summaryCadence = .threeMinutes
        preferences.includeLocalMicrophone = false
        let reloaded = MeetingPreferences(defaults: defaults)

        XCTAssertEqual(reloaded.summaryCadence, .threeMinutes)
        XCTAssertFalse(reloaded.includeLocalMicrophone)
    }
}
