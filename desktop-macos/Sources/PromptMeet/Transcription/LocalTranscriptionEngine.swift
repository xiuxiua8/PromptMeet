import Foundation

protocol LocalTranscriptionEngine: Sendable {
    func prepare() async throws
    func transcribe(_ segment: PCMTranscriptionSegment) async throws -> String
    func shutdown() async
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
        case let .processFailed(message):
            "本地转写失败：\(message)"
        case .serverStartFailed:
            "本地 Whisper 模型启动超时"
        }
    }
}
