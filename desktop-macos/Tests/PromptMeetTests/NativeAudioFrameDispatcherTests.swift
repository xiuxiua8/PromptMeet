import Foundation
import XCTest

@testable import PromptMeet

final class NativeAudioFrameDispatcherTests: XCTestCase {
  func testBatchesUploadWithoutDelayingTranscription() async {
    let uploader = RecordingNativeAudioUploader()
    let packetPump = NativeAudioPacketPump(uploader: uploader, sessionID: "remote-session")
    let transcription = OrderedLocalTranscriptionServiceSpy()
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: packetPump,
      transcription: transcription
    )

    for index in 0..<50 {
      dispatcher.enqueue(twentyMillisecondPCM(index: index))
    }
    await dispatcher.drain()

    let transcriptionTimes = await transcription.meetingTimes
    let uploadedPackets = await uploader.packets
    XCTAssertEqual(transcriptionTimes.count, 50)
    XCTAssertEqual(uploadedPackets.count, 1)
    XCTAssertEqual(uploadedPackets.first?.payload.count, 32_000)
  }

  func testDropsIncompleteUploadBatchAcrossSuspension() async {
    let uploader = RecordingNativeAudioUploader()
    let packetPump = NativeAudioPacketPump(uploader: uploader, sessionID: "remote-session")
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: packetPump,
      transcription: OrderedLocalTranscriptionServiceSpy()
    )

    for index in 0..<25 {
      dispatcher.enqueue(twentyMillisecondPCM(index: index))
    }
    await dispatcher.suspend()
    await dispatcher.resume()
    for index in 25..<50 {
      dispatcher.enqueue(twentyMillisecondPCM(index: index))
    }
    await dispatcher.drain()

    let uploadedPackets = await uploader.packets
    XCTAssertTrue(uploadedPackets.isEmpty)
  }

  private func twentyMillisecondPCM(index: Int) -> CapturedPCM {
    CapturedPCM(
      source: .system,
      sampleRate: 16_000,
      channels: 1,
      meetingTime: .milliseconds(Int64(index * 20)),
      payload: Data(repeating: UInt8(index), count: 640)
    )
  }
}
