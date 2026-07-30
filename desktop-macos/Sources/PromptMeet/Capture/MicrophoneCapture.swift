import AVFoundation
import Foundation

protocol MicrophoneVoiceProcessingControlling: AnyObject {
  var isVoiceProcessingEnabled: Bool { get }
  func setVoiceProcessingEnabled(_ enabled: Bool) throws
}

enum MicrophoneVoiceProcessingMode: Equatable, Sendable {
  case enabled
  case unprocessedFallback
}

enum MicrophoneVoiceProcessing {
  static func enableIfSupported(
    _ controller: any MicrophoneVoiceProcessingControlling
  ) -> MicrophoneVoiceProcessingMode {
    if controller.isVoiceProcessingEnabled {
      return .enabled
    }
    do {
      try controller.setVoiceProcessingEnabled(true)
      return controller.isVoiceProcessingEnabled ? .enabled : .unprocessedFallback
    } catch {
      return .unprocessedFallback
    }
  }
}

private final class AVAudioInputVoiceProcessingController: MicrophoneVoiceProcessingControlling {
  private let input: AVAudioInputNode

  init(input: AVAudioInputNode) {
    self.input = input
  }

  var isVoiceProcessingEnabled: Bool {
    input.isVoiceProcessingEnabled
  }

  func setVoiceProcessingEnabled(_ enabled: Bool) throws {
    try input.setVoiceProcessingEnabled(enabled)
  }
}

final class MicrophoneCapture: NativeAudioSourceCapture, @unchecked Sendable {
  let source = NativeAudioSource.microphone
  private let engine = AVAudioEngine()
  private let permission: any MicrophonePermissionProviding
  private let lock = NSLock()
  private var handler: (@Sendable (CapturedPCM) -> Void)?
  private var failureHandler: (@Sendable (any Error) -> Void)?
  private var tapInstalled = false
  private var configurationObserver: NSObjectProtocol?

  init(permission: any MicrophonePermissionProviding = SystemMicrophonePermission()) {
    self.permission = permission
  }

  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
    switch await MicrophonePermissionResolver(permission: permission).resolveForUserStart() {
    case .authorized:
      break
    case .notDetermined, .denied:
      throw CaptureError.microphoneDenied
    case .restricted:
      throw CaptureError.microphoneRestricted
    case .unavailable:
      throw CaptureError.microphoneUnavailable
    }
    lock.withLock { self.handler = handler }

    let input = engine.inputNode
    _ = MicrophoneVoiceProcessing.enableIfSupported(
      AVAudioInputVoiceProcessingController(input: input)
    )
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0 else {
      lock.withLock { self.handler = nil }
      throw CaptureError.microphoneUnavailable
    }
    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
      self?.consume(buffer)
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      tapInstalled = false
      lock.withLock { self.handler = nil }
      throw CaptureError.microphoneRuntimeFailure(error.localizedDescription)
    }
  }

  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws {
    lock.withLock { failureHandler = onFailure }
    do {
      try await start(handler: handler)
      observeRuntimeConfiguration()
    } catch {
      lock.withLock { failureHandler = nil }
      throw error
    }
  }

  func stop() async {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    lock.withLock { failureHandler = nil }
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.stop()
    lock.withLock { handler = nil }
  }

  private func observeRuntimeConfiguration() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self, !engine.isRunning else { return }
      let failure = lock.withLock { failureHandler }
      failure?(CaptureError.microphoneRuntimeFailure("音频设备配置发生变化"))
    }
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
