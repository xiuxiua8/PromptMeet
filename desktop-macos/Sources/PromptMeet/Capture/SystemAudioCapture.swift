import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, NativeAudioSourceCapture,
    SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
    let source = NativeAudioSource.system
    private let lock = NSLock()
    private var handler: (@Sendable (CapturedPCM) -> Void)?
    private var failureHandler: (@Sendable (any Error) -> Void)?
    private var stream: SCStream?
    private let permission: any ScreenRecordingPermissionProviding
    private let outputQueue = DispatchQueue(label: "com.promptmeet.capture.system-audio")

    init(permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission()) {
        self.permission = permission
    }

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        guard
            await ScreenRecordingPermissionResolver(
                permission: permission
            ).resolveForUserAction()
        else {
            throw CaptureError.screenRecordingDenied
        }
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

    func start(
        handler: @escaping @Sendable (CapturedPCM) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) async throws {
        lock.withLock { failureHandler = onFailure }
        do {
            try await start(handler: handler)
        } catch {
            lock.withLock { failureHandler = nil }
            throw error
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        lock.withLock {
            handler = nil
            failureHandler = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let failure = lock.withLock { failureHandler }
        failure?(CaptureError.systemAudioRuntimeFailure(error.localizedDescription))
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
    case microphoneRestricted
    case microphoneUnavailable
    case microphoneRuntimeFailure(String)
    case screenRecordingDenied
    case systemAudioRuntimeFailure(String)
    case unsupportedAudioFormat
    case noAvailableAudioSource(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "未找到可采集的显示器"
        case .microphoneDenied: "麦克风权限未授权"
        case .microphoneRestricted: "麦克风访问受系统限制"
        case .microphoneUnavailable: "未找到可用的麦克风"
        case .microphoneRuntimeFailure(let detail): "麦克风采集失败：\(detail)"
        case .screenRecordingDenied: "屏幕录制权限未授权，系统音频不可用"
        case .systemAudioRuntimeFailure(let detail): "系统音频采集失败：\(detail)"
        case .unsupportedAudioFormat: "当前音频格式不受支持"
        case .noAvailableAudioSource(let detail): "没有可用的音频来源：\(detail)"
        }
    }
}
