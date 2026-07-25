import AVFoundation
import Foundation

final class MicrophoneCapture: NativeAudioSourceCapture, @unchecked Sendable {
    let source = NativeAudioSource.microphone
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedPCM) -> Void)?

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureError.microphoneDenied }
        lock.withLock { self.handler = handler }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw CaptureError.unsupportedAudioFormat }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { handler = nil }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let clamped = max(-1, min(1, channel[index]))
            samples.append(Int16(clamped * Float(Int16.max)))
        }
        let data = samples.withUnsafeBytes { Data($0) }
        let callback = lock.withLock { handler }
        callback?(
            CapturedPCM(
                source: .microphone,
                sampleRate: Int(buffer.format.sampleRate),
                channels: 1,
                payload: data
            )
        )
    }
}
