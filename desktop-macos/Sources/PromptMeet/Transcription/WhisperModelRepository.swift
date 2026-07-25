import Foundation

struct WhisperModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let filename: String
    let sizeBytes: Int64
    let detail: String
    let downloadURL: URL

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum WhisperModelCatalog {
    static let models: [WhisperModelDescriptor] = [
        model("tiny", "Tiny", "ggml-tiny.bin", 75_000_000, "最快 · 适合快速字幕"),
        model("base", "Base", "ggml-base.bin", 142_000_000, "轻量 · 日常会议"),
        model("small", "Small", "ggml-small.bin", 466_000_000, "平衡 · 推荐"),
        model(
            "large-v3-turbo-q5_0",
            "Large V3 Turbo",
            "ggml-large-v3-turbo-q5_0.bin",
            574_000_000,
            "高准确率 · 需要更多内存"
        ),
        model(
            "large-v3-turbo",
            "Large V3 Turbo 精确版",
            "ggml-large-v3-turbo.bin",
            1_620_000_000,
            "最高准确率 · 未量化 · 推荐高性能 Mac"
        )
    ]

    static func descriptor(id: String) -> WhisperModelDescriptor? {
        models.first { $0.id == id }
    }

    private static func model(
        _ id: String,
        _ displayName: String,
        _ filename: String,
        _ sizeBytes: Int64,
        _ detail: String
    ) -> WhisperModelDescriptor {
        WhisperModelDescriptor(
            id: id,
            displayName: displayName,
            filename: filename,
            sizeBytes: sizeBytes,
            detail: detail,
            downloadURL: URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)?download=true"
            )!
        )
    }
}

struct WhisperModelRepository: Sendable {
    let modelsDirectory: URL

    init(modelsDirectory: URL = Self.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
            .appendingPathComponent("whisper-models", isDirectory: true)
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
    }

    func installedModels() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "bin" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    func modelURL(for descriptor: WhisperModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent(descriptor.filename)
    }

    func isInstalled(_ descriptor: WhisperModelDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: descriptor).path)
    }

    func remove(_ descriptor: WhisperModelDescriptor) throws {
        let url = modelURL(for: descriptor)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

final class WhisperPreferences: @unchecked Sendable {
    private enum Key {
        static let selectedModelID = "whisper.selectedModelID"
        static let language = "whisper.language"
        static let translationEnabled = "whisper.translationEnabled"
        static let translationTargetLanguage = "whisper.translationTargetLanguage"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedModelID: String {
        get { defaults.string(forKey: Key.selectedModelID) ?? "small" }
        set { defaults.set(newValue, forKey: Key.selectedModelID) }
    }

    var language: String {
        get { defaults.string(forKey: Key.language) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    var translationEnabled: Bool {
        get { defaults.bool(forKey: Key.translationEnabled) }
        set { defaults.set(newValue, forKey: Key.translationEnabled) }
    }

    var translationTargetLanguage: String {
        get { defaults.string(forKey: Key.translationTargetLanguage) ?? "zh" }
        set { defaults.set(newValue, forKey: Key.translationTargetLanguage) }
    }
}
