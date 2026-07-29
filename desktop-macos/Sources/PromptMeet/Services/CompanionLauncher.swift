import Foundation

@MainActor
protocol CompanionLaunching: AnyObject {
    func ensureRunning() async throws
    func reloadConfiguration() async throws
    func stopOwnedProcess()
}

enum CompanionLauncherError: LocalizedError {
    case backendNotFound
    case startupTimedOut
    case configurationRequiresAppRestart

    var errorDescription: String? {
        switch self {
        case .backendNotFound: "未找到 PromptMeet Python companion"
        case .startupTimedOut: "Python companion 启动超时"
        case .configurationRequiresAppRestart: "AI 服务由其他 PromptMeet 进程提供，请重启应用后重试"
        }
    }
}

struct CompanionLaunchConfiguration: Equatable, Sendable {
    let pythonURL: URL
    let scriptURL: URL
    let workingDirectory: URL
    let environmentFileURL: URL?
}

enum CompanionRuntimeLocator {
    static func resolve(
        resourceURL: URL?,
        bundleURL: URL,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> CompanionLaunchConfiguration {
        var repositoryRoots: [URL] = []
        var bundleParent = bundleURL.deletingLastPathComponent()
        if bundleParent.lastPathComponent == "dist" {
            bundleParent.deleteLastPathComponent()
            repositoryRoots.append(bundleParent)
        }
        var currentRoot = currentDirectory
        if currentRoot.lastPathComponent == "desktop-macos" {
            currentRoot.deleteLastPathComponent()
        }
        repositoryRoots.append(currentRoot)

        let bundledScript = resourceURL?.appendingPathComponent("companion/backend/main_service.py")
        let scriptCandidates = [bundledScript].compactMap { $0 } + repositoryRoots.map {
            $0.appendingPathComponent("backend/main_service.py")
        }
        guard let scriptURL = scriptCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw CompanionLauncherError.backendNotFound
        }

        let bundledPythonRoot = resourceURL?.appendingPathComponent("companion/python/bin")
        let pythonCandidates = [
            bundledPythonRoot?.appendingPathComponent("python3"),
            bundledPythonRoot?.appendingPathComponent("python")
        ].compactMap { $0 } + repositoryRoots.flatMap { root in
            [
                root.appendingPathComponent("build/desktop-python/bin/python3"),
                root.appendingPathComponent("build/desktop-python/bin/python"),
                root.appendingPathComponent("backend/venv/bin/python")
            ]
        }
        guard let pythonURL = pythonCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CompanionLauncherError.backendNotFound
        }
        let environmentFileURL = repositoryRoots
            .map { $0.appendingPathComponent(".env") }
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        return CompanionLaunchConfiguration(
            pythonURL: pythonURL,
            scriptURL: scriptURL,
            workingDirectory: scriptURL.deletingLastPathComponent(),
            environmentFileURL: environmentFileURL
        )
    }
}

@MainActor
final class CompanionLauncher: CompanionLaunching {
    private let environment: BackendEnvironment
    private let keychain: KeychainStore
    private var ownedProcess: Process?
    private var ownedLogHandle: FileHandle?

    init(environment: BackendEnvironment = .local, keychain: KeychainStore = KeychainStore()) {
        self.environment = environment
        self.keychain = keychain
    }

    func ensureRunning() async throws {
        if await isHealthy() { return }
        if ownedProcess?.isRunning != true {
            ownedProcess = try launchDevelopmentCompanion()
        }

        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if await isHealthy() { return }
            if ownedProcess?.isRunning == false { break }
        }
        throw CompanionLauncherError.startupTimedOut
    }

    func stopOwnedProcess() {
        guard let process = ownedProcess else { return }
        if process.isRunning {
            process.terminate()
        }
        ownedProcess = nil
        try? ownedLogHandle?.close()
        ownedLogHandle = nil
    }

    func reloadConfiguration() async throws {
        guard ownedProcess != nil else {
            if await isHealthy() {
                throw CompanionLauncherError.configurationRequiresAppRestart
            }
            return try await ensureRunning()
        }
        stopOwnedProcess()
        for _ in 0..<20 {
            if !(await isHealthy()) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await ensureRunning()
    }

    private func isHealthy() async -> Bool {
        do {
            let request = environment.request(path: "/health")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func launchDevelopmentCompanion() throws -> Process {
        let fileManager = FileManager.default
        let configuration = try CompanionRuntimeLocator.resolve(
            resourceURL: Bundle.main.resourceURL,
            bundleURL: Bundle.main.bundleURL,
            currentDirectory: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        )
        let process = Process()
        process.executableURL = configuration.pythonURL
        process.arguments = [configuration.scriptURL.path]
        process.currentDirectoryURL = configuration.workingDirectory

        let logsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet/logs", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("companion.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        ownedLogHandle = logHandle
        process.standardOutput = logHandle
        process.standardError = logHandle

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PYTHONUNBUFFERED"] = "1"
        processEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
        processEnvironment["PROMPTMEET_DESKTOP_MODE"] = "1"
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
        processEnvironment["PROMPTMEET_DATA_DIR"] = applicationSupport.path
        processEnvironment["PROMPTMEET_WORK_DIR"] = applicationSupport
            .appendingPathComponent("temp_sessions", isDirectory: true).path
        if let environmentFileURL = configuration.environmentFileURL {
            processEnvironment["PROMPTMEET_ENV_FILE"] = environmentFileURL.path
        }
        if let openAIKey = try? keychain.read(
            service: "com.promptmeet.desktop",
            account: "OPENAI_API_KEY"
        ) {
            processEnvironment["OPENAI_API_KEY"] = openAIKey
        }
        if let deepSeekKey = try? keychain.read(
            service: "com.promptmeet.desktop",
            account: "DEEPSEEK_API_KEY"
        ) {
            processEnvironment["DEEPSEEK_API_KEY"] = deepSeekKey
        }
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: AIProviderPreferenceKey.provider) ?? "deepseek"
        let providerEnvironment = try AIProviderPreferences(defaults: defaults)
            .runtimeEnvironment(providerID: provider)
        processEnvironment.merge(providerEnvironment) { _, configured in configured }
        process.environment = processEnvironment
        try process.run()
        return process
    }
}
