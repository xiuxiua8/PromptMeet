import Foundation
import XCTest

@testable import PromptMeet

final class NativeAudioUploadBatcherTests: XCTestCase {
  func testCoalescesOneSecondOfTwentyMillisecondFrames() {
    var batcher = NativeAudioUploadBatcher()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var emitted: [CapturedPCM] = []

    for index in 0..<50 {
      emitted.append(
        contentsOf: batcher.append(
          CapturedPCM(
            source: .system,
            sampleRate: 16_000,
            channels: 1,
            capturedAt: startedAt.addingTimeInterval(Double(index) * 0.02),
            meetingTime: .milliseconds(Int64(index * 20)),
            payload: Data(repeating: UInt8(index), count: 640)
          )
        )
      )
    }

    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(emitted.first?.source, .system)
    XCTAssertEqual(emitted.first?.sampleRate, 16_000)
    XCTAssertEqual(emitted.first?.channels, 1)
    XCTAssertEqual(emitted.first?.capturedAt, startedAt)
    XCTAssertEqual(emitted.first?.meetingTime, .zero)
    XCTAssertEqual(emitted.first?.payload.count, 32_000)
  }

  func testFlushesBeforeASourceFormatChange() {
    var batcher = NativeAudioUploadBatcher()
    let startedAt = Date(timeIntervalSince1970: 2_000)
    let initial = CapturedPCM(
      source: .system,
      sampleRate: 16_000,
      channels: 1,
      capturedAt: startedAt,
      meetingTime: .seconds(3),
      payload: Data(repeating: 1, count: 16_000)
    )
    let changed = CapturedPCM(
      source: .system,
      sampleRate: 48_000,
      channels: 2,
      capturedAt: startedAt.addingTimeInterval(0.5),
      meetingTime: .milliseconds(3_500),
      payload: Data(repeating: 2, count: 1_920)
    )

    XCTAssertTrue(batcher.append(initial).isEmpty)
    let emitted = batcher.append(changed)

    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(emitted.first?.sampleRate, 16_000)
    XCTAssertEqual(emitted.first?.channels, 1)
    XCTAssertEqual(emitted.first?.capturedAt, startedAt)
    XCTAssertEqual(emitted.first?.meetingTime, .seconds(3))
    XCTAssertEqual(emitted.first?.payload.count, 16_000)
  }
}
