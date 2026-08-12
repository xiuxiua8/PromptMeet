import Foundation

protocol LocalTranscriptionEngine: Sendable {
  func prepare() async throws
  func transcribe(_ segment: PCMTranscriptionSegment) async throws -> String
  func shutdown() async
}

protocol LocalTranscriptionEngineBuilding: Sendable {
  func makeEngine() throws -> any LocalTranscriptionEngine
}

struct WhisperServerEngineBuilder: LocalTranscriptionEngineBuilding {
  let repository: WhisperModelRepository
  let preferences: WhisperPreferences

  init(
    repository: WhisperModelRepository = WhisperModelRepository(),
    preferences: WhisperPreferences = WhisperPreferences()
  ) {
    self.repository = repository
    self.preferences = preferences
  }

  func makeEngine() throws -> any LocalTranscriptionEngine {
    try repository.prepareDirectory()
    guard
      let descriptor = WhisperModelCatalog.descriptor(id: preferences.selectedModelID),
      repository.isInstalled(descriptor)
    else {
      throw LocalTranscriptionError.modelNotInstalled
    }
    guard let executableURL = WhisperRuntimeLocator.serverExecutableURL() else {
      throw LocalTranscriptionError.runtimeNotInstalled
    }
    return WhisperServerEngine(
      executableURL: executableURL,
      modelURL: repository.modelURL(for: descriptor),
      language: preferences.language
    )
  }
}

extension LocalTranscriptionEngine {
  func prepare() async throws {}
  func shutdown() async {}
}

enum LocalTranscriptionError: LocalizedError {
  case modelNotInstalled
  case runtimeNotInstalled
  case processFailed(String)
  case serverStartFailed

  var errorDescription: String? {
    switch self {
    case .modelNotInstalled:
      "请先在“设置 → 采集”下载并选择本地转写模型"
    case .runtimeNotInstalled:
      "本地 Whisper 运行时缺失，请重新构建或安装 PromptMeet"
    case .processFailed(let message):
      "本地转写失败：\(message)"
    case .serverStartFailed:
      "本地 Whisper 模型启动超时"
    }
  }
}
