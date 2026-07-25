import Combine
import Foundation

@MainActor
final class WhisperModelLibrary: ObservableObject {
    @Published private(set) var installedFilenames: Set<String> = []
    @Published private(set) var downloadingModelID: String?
    @Published private(set) var downloadProgress = 0.0
    @Published var errorMessage: String?
    @Published var selectedModelID: String {
        didSet { preferences.selectedModelID = selectedModelID }
    }
    @Published var language: String {
        didSet { preferences.language = language }
    }
    @Published var translationEnabled: Bool {
        didSet { preferences.translationEnabled = translationEnabled }
    }
    @Published var translationTargetLanguage: String {
        didSet { preferences.translationTargetLanguage = translationTargetLanguage }
    }

    let repository: WhisperModelRepository
    private let preferences: WhisperPreferences
    private var downloader: WhisperModelDownloader?
    private var downloadTask: Task<Void, Never>?

    init(
        repository: WhisperModelRepository = WhisperModelRepository(),
        preferences: WhisperPreferences = WhisperPreferences()
    ) {
        self.repository = repository
        self.preferences = preferences
        selectedModelID = preferences.selectedModelID
        language = preferences.language
        translationEnabled = preferences.translationEnabled
        translationTargetLanguage = preferences.translationTargetLanguage
        refresh()
    }

    func refresh() {
        try? repository.prepareDirectory()
        installedFilenames = Set(repository.installedModels().map(\.lastPathComponent))
    }

    func isInstalled(_ model: WhisperModelDescriptor) -> Bool {
        installedFilenames.contains(model.filename)
    }

    func select(_ model: WhisperModelDescriptor) {
        guard isInstalled(model) else { return }
        selectedModelID = model.id
    }

    func download(_ model: WhisperModelDescriptor) {
        guard downloadingModelID == nil, !isInstalled(model) else { return }
        errorMessage = nil
        downloadingModelID = model.id
        downloadProgress = 0
        let operation = WhisperModelDownloader(
            destinationURL: repository.modelURL(for: model)
        ) { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        }
        downloader = operation
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation.download(from: model.downloadURL)
                refresh()
                select(model)
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadingModelID = nil
            downloadProgress = 0
            downloader = nil
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloader?.cancel()
        downloadTask?.cancel()
    }

    func remove(_ model: WhisperModelDescriptor) {
        do {
            try repository.remove(model)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private final class WhisperModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var finished = false

    init(destinationURL: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destinationURL = destinationURL
        self.progress = progress
    }

    func download(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                let configuration = URLSessionConfiguration.default
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            progress(1)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard !finished else { return nil }
            finished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
