import XCTest

@testable import PromptMeet

final class MicrophoneVoiceProcessingTests: XCTestCase {
  func testSupportedVoiceProcessingIsEnabled() {
    let controller = VoiceProcessingControllerSpy()

    let result = MicrophoneVoiceProcessing.enableIfSupported(controller)

    XCTAssertEqual(result, .enabled)
    XCTAssertEqual(controller.requestedValues, [true])
  }

  func testAlreadyEnabledVoiceProcessingIsIdempotent() {
    let controller = VoiceProcessingControllerSpy(isEnabled: true)

    let result = MicrophoneVoiceProcessing.enableIfSupported(controller)

    XCTAssertEqual(result, .enabled)
    XCTAssertEqual(controller.requestedValues, [])
  }

  func testUnsupportedVoiceProcessingFallsBackWithoutFailingCapture() {
    let controller = VoiceProcessingControllerSpy(error: VoiceProcessingTestError.unsupported)

    let result = MicrophoneVoiceProcessing.enableIfSupported(controller)

    XCTAssertEqual(result, .unprocessedFallback)
    XCTAssertEqual(controller.requestedValues, [true])
  }

  func testVoiceProcessingThatDoesNotBecomeActiveUsesFallback() {
    let controller = VoiceProcessingControllerSpy(activatesWhenRequested: false)

    let result = MicrophoneVoiceProcessing.enableIfSupported(controller)

    XCTAssertEqual(result, .unprocessedFallback)
  }
}

private enum VoiceProcessingTestError: Error {
  case unsupported
}

private final class VoiceProcessingControllerSpy: MicrophoneVoiceProcessingControlling {
  private(set) var isVoiceProcessingEnabled: Bool
  private(set) var requestedValues: [Bool] = []
  private let activatesWhenRequested: Bool
  private let error: (any Error)?

  init(
    isEnabled: Bool = false,
    activatesWhenRequested: Bool = true,
    error: (any Error)? = nil
  ) {
    isVoiceProcessingEnabled = isEnabled
    self.activatesWhenRequested = activatesWhenRequested
    self.error = error
  }

  func setVoiceProcessingEnabled(_ enabled: Bool) throws {
    requestedValues.append(enabled)
    if let error { throw error }
    if activatesWhenRequested {
      isVoiceProcessingEnabled = enabled
    }
  }
}
