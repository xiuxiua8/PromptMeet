import Foundation
import XCTest
@testable import PromptMeet

final class CompanionRuntimeLocatorTests: XCTestCase {
    func testOpenAICompatibleRuntimeEnvironmentUsesPersistedEndpointAndModelEverywhere() throws {
        let suiteName = "CompanionRuntimePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://localhost:52251/v1/", forKey: AIProviderPreferenceKey.openAIBaseURL)
        defaults.set("captain-proxy-model", forKey: AIProviderPreferenceKey.openAIModel)
        let preferences = AIProviderPreferences(defaults: defaults)

        let environment = try preferences.runtimeEnvironment(providerID: "openai")

        XCTAssertEqual(environment["PROMPTMEET_AI_PROVIDER"], "openai")
        XCTAssertEqual(environment["OPENAI_API_BASE"], "http://localhost:52251/v1")
        XCTAssertEqual(environment["OPENAI_ANSWER_MODEL"], "captain-proxy-model")
        XCTAssertEqual(environment["OPENAI_QUESTION_MODEL"], "captain-proxy-model")
        XCTAssertFalse(environment.keys.contains("OPENAI_API_KEY"))
    }

    func testLocatorPrefersBundledDesktopCompanionAndPython() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = root.appendingPathComponent("Resources")
        let script = resources.appendingPathComponent("companion/backend/main_service.py")
        let python = resources.appendingPathComponent("companion/python/bin/python3")
        let scriptDir = script.deletingLastPathComponent()
        let pythonDir = python.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pythonDir, withIntermediateDirectories: true)
        try Data().write(to: script)
        try Data().write(to: python)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: python.path)

        let configuration = try CompanionRuntimeLocator.resolve(
            resourceURL: resources,
            bundleURL: root.appendingPathComponent("PromptMeet.app"),
            currentDirectory: URL(fileURLWithPath: "/")
        )

        XCTAssertEqual(configuration.scriptURL, script)
        XCTAssertEqual(configuration.pythonURL, python)
        XCTAssertEqual(
            configuration.workingDirectory, script.deletingLastPathComponent())
        XCTAssertNil(configuration.environmentFileURL)
    }

    func testLocatorFindsRepositoryEnvironmentForBundledApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dist = root.appendingPathComponent("dist")
        let bundle = dist.appendingPathComponent("PromptMeet.app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let script = resources
            .appendingPathComponent("companion/backend/main_service.py")
        let python = resources
            .appendingPathComponent("companion/python/bin/python3")
        let environment = root.appendingPathComponent(".env")
        let dir = script.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: script)
        try Data().write(to: python)
        try Data("DB_HOST=localhost".utf8).write(to: environment)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let configuration = try CompanionRuntimeLocator.resolve(
            resourceURL: resources,
            bundleURL: bundle,
            currentDirectory: URL(fileURLWithPath: "/")
        )

        XCTAssertEqual(configuration.environmentFileURL, environment)
    }
}
