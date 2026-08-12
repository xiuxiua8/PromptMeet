import XCTest

@testable import PromptMeet

final class CapturePermissionTests: XCTestCase {
    func testNotDeterminedRequestsOnceThenStartsOnlyWhenAuthorized() async {
        let permission = MicrophonePermissionSpy(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let resolver = MicrophonePermissionResolver(permission: permission)

        let result = await resolver.resolveForUserStart()

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(permission.requestCount, 1)
    }

    func testAuthorizedDoesNotRequestAgain() async {
        let permission = MicrophonePermissionSpy(status: .authorized)
        let resolver = MicrophonePermissionResolver(permission: permission)

        let result = await resolver.resolveForUserStart()

        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(permission.requestCount, 0)
    }

    func testDeniedDoesNotRequestAgainAndOffersSettingsRecovery() async {
        let permission = MicrophonePermissionSpy(status: .denied)
        let resolver = MicrophonePermissionResolver(permission: permission)

        let result = await resolver.resolveForUserStart()

        XCTAssertEqual(result, .denied)
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertTrue(result.canOpenSystemSettings)
    }

    func testRestrictedAndUnavailableRemainDistinct() async {
        let restricted = await MicrophonePermissionResolver(
            permission: MicrophonePermissionSpy(status: .restricted)
        ).resolveForUserStart()
        let unavailable = await MicrophonePermissionResolver(
            permission: MicrophonePermissionSpy(status: .unavailable)
        ).resolveForUserStart()

        XCTAssertEqual(restricted, .restricted)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertNotEqual(restricted, unavailable)
    }

    func testScreenRecordingPermissionIsRequestedOnlyAtUserAction() async {
        let permission = ScreenRecordingPermissionSpy(hasAccess: false, requestResult: true)
        let resolver = ScreenRecordingPermissionResolver(permission: permission)

        XCTAssertFalse(resolver.hasAccess)
        XCTAssertEqual(permission.requestCount, 0)
        let result = await resolver.resolveForUserAction()
        XCTAssertTrue(result)
        XCTAssertEqual(permission.requestCount, 1)
    }

    func testPrivacySettingsURLsPointAtTheirSpecificRecoveryPanes() {
        XCTAssertEqual(
            CapturePermissionSettingsURL.microphone.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        XCTAssertEqual(
            CapturePermissionSettingsURL.screenRecording.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }
}

private final class MicrophonePermissionSpy: MicrophonePermissionProviding, @unchecked Sendable {
    private(set) var requestCount = 0
    var authorizationState: MicrophoneAuthorizationState
    private let requestedStatus: MicrophoneAuthorizationState

    init(
        status: MicrophoneAuthorizationState,
        requestedStatus: MicrophoneAuthorizationState = .denied
    ) {
        authorizationState = status
        self.requestedStatus = requestedStatus
    }

    func requestAuthorization() async -> MicrophoneAuthorizationState {
        requestCount += 1
        authorizationState = requestedStatus
        return requestedStatus
    }

    func openSystemSettings() {}
}

private final class ScreenRecordingPermissionSpy: ScreenRecordingPermissionProviding,
    @unchecked Sendable {
    var hasAccess: Bool
    private let requestResult: Bool
    private(set) var requestCount = 0

    init(hasAccess: Bool, requestResult: Bool) {
        self.hasAccess = hasAccess
        self.requestResult = requestResult
    }

    func requestAccess() -> Bool {
        requestCount += 1
        hasAccess = requestResult
        return requestResult
    }

    func openSystemSettings() {}
}
