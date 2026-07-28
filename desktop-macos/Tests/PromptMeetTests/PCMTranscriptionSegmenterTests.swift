import Foundation
import XCTest

@testable import PromptMeet

final class PCMTranscriptionSegmenterTests: XCTestCase {
    func testLocalTranscriptionKeepsOriginalEightSecondChunksByDefault() {
        XCTAssertEqual(LocalTranscriptionService.defaultSegmentDuration, 8)
    }

    func testDefaultStreamingPreviewKeepsOriginalOnePointTwoFiveSecondCadence() {
        var segmenter = PCMTranscriptionSegmenter()
        let earlySamples = [Int16](repeating: 1_000, count: 12_000).data
        let remainingSamples = [Int16](repeating: 1_000, count: 8_000).data

        let early = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: earlySamples)
        )
        let originalCadence = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: remainingSamples)
        )

        XCTAssertNil(early.preview)
        XCTAssertEqual(originalCadence.preview?.samples.count, 20_000)
        XCTAssertTrue(originalCadence.finalized.isEmpty)
    }

    func testStreamingPreviewRefreshesBeforeLongSegmentIsFinalized() {
        var segmenter = PCMTranscriptionSegmenter(
            segmentDuration: 4,
            previewInterval: 1,
            minimumPreviewDuration: 1
        )
        let oneSecond = [Int16](repeating: 1_000, count: 16_000).data

        let first = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
        )
        let second = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
        )
        _ = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
        )
        let finalized = segmenter.consumeStreaming(
            CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
        )

        XCTAssertEqual(first.preview?.samples.count, 16_000)
        XCTAssertEqual(second.preview?.samples.count, 32_000)
        XCTAssertTrue(first.finalized.isEmpty)
        XCTAssertEqual(finalized.finalized.first?.samples.count, 64_000)
        XCTAssertNil(finalized.preview)
    }

    func testSegmenterEmitsThreeSecondMonoSegmentAt16kHz() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3)
        let samples = [Int16](repeating: 1_000, count: 48_000)
        let packet = CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: samples.data)

        let output = segmenter.consume(packet)

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].source, .system)
        XCTAssertEqual(output[0].samples.count, 48_000)
        XCTAssertEqual(output[0].sampleRate, 16_000)
    }

    func testSegmentKeepsFirstCaptureTimeAndMeetingOffset() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
        let capturedAt = Date(timeIntervalSince1970: 100)
        let samples = [Int16](repeating: 1_000, count: 16_000)

        let output = segmenter.consume(
            CapturedPCM(
                source: .microphone,
                sampleRate: 16_000,
                channels: 1,
                capturedAt: capturedAt,
                meetingTime: .milliseconds(1_250),
                payload: samples.data
            )
        )

        XCTAssertEqual(output.first?.capturedAt, capturedAt)
        XCTAssertEqual(output.first?.meetingTime, .milliseconds(1_250))
    }

    func testSegmenterKeepsSourcesSeparateAndFlushesRemainder() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3, minimumFlushDuration: 0.5)
        let oneSecond = [Int16](repeating: 500, count: 16_000).data

        XCTAssertTrue(
            segmenter.consume(CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: oneSecond)).isEmpty
        )
        XCTAssertTrue(
            segmenter.consume(CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond))
                .isEmpty)

        let flushed = segmenter.flush()
        XCTAssertEqual(Set(flushed.map(\.source)), Set([.system, .microphone]))
        XCTAssertEqual(flushed.map(\.samples.count).sorted(), [16_000, 16_000])
    }

    func testPauseBoundaryDiscardsBufferedAudioInsteadOfReplayingIt() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3, minimumFlushDuration: 0.5)
        let oneSecond = [Int16](repeating: 500, count: 16_000).data
        _ = segmenter.consume(
            CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: oneSecond)
        )

        segmenter.discardBufferedAudio()

        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testSegmenterResamples48kHzInput() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
        let samples = [Int16](repeating: 800, count: 48_000)

        let output = segmenter.consume(
            CapturedPCM(source: .microphone, sampleRate: 48_000, channels: 1, payload: samples.data)
        )

        XCTAssertEqual(output.first?.samples.count, 16_000)
    }

    func testWaveWriterCreatesPCM16Header() throws {
        let data = PCM16WaveWriter.data(samples: [0, 1, -1], sampleRate: 16_000)

        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 50)
    }

    func testFloatSamplesAreClampedAndEncodedAsPCM16() {
        let data = PCM16SampleEncoder.data(floatSamples: [-2, -1, 0, 1, 2])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

        XCTAssertEqual(samples, [Int16.min + 1, Int16.min + 1, 0, Int16.max, Int16.max])
    }

    func testNearSilentSegmentIsNotSentToWhisper() {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
        let roomNoise = [Int16](repeating: 20, count: 16_000)

        XCTAssertTrue(
            segmenter.consume(
                CapturedPCM(
                    source: .microphone,
                    sampleRate: 16_000,
                    channels: 1,
                    payload: roomNoise.data
                )
            ).isEmpty
        )
    }
}

extension Array where Element == Int16 {
    fileprivate var data: Data { withUnsafeBytes { Data($0) } }
}
