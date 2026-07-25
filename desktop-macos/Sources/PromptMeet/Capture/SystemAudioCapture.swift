import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, NativeAudioSourceCapture,
    SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let source = NativeAudioSource.system
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedPCM) -> Void)?
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.promptmeet.capture.system-audio")

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        lock.withLock { self.handler = handler }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        lock.withLock { handler = nil }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let data = Self.audioData(from: sampleBuffer), !data.isEmpty else { return }
        let callback = lock.withLock { handler }
        callback?(
            CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: data)
        )
    }

    private static func audioData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        let format = basicDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            return PCM16SampleEncoder.data(float32Data: data)
        }
        if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, format.mBitsPerChannel == 16 {
            return data
        }
        return nil
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case microphoneDenied
    case unsupportedAudioFormat
    case noAvailableAudioSource(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "未找到可采集的显示器"
        case .microphoneDenied: "麦克风权限未授权"
        case .unsupportedAudioFormat: "当前音频格式不受支持"
        case let .noAvailableAudioSource(detail): "没有可用的音频来源：\(detail)"
        }
    }
}
