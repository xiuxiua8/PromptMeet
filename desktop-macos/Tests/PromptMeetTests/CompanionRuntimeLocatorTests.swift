import Foundation
import XCTest
@testable import PromptMeet

final class CompanionRuntimeLocatorTests: XCTestCase {
    func testLocatorPrefersBundledDesktopCompanionAndPython() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = root.appendingPathComponent("Resources")
        let script = resources.appendingPathComponent("companion/backend/main_service.py")
        let python = resources.appendingPathComponent("companion/python/bin/python3")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        try Data().write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let configuration = try CompanionRuntimeLocator.resolve(
            resourceURL: resources,
            bundleURL: root.appendingPathComponent("PromptMeet.app"),
            currentDirectory: URL(fileURLWithPath: "/")
        )

        XCTAssertEqual(configuration.scriptURL, script)
        XCTAssertEqual(configuration.pythonURL, python)
        XCTAssertEqual(configuration.workingDirectory, script.deletingLastPathComponent())
        XCTAssertNil(configuration.environmentFileURL)
    }

    func testLocatorFindsRepositoryEnvironmentForBundledApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dist = root.appendingPathComponent("dist")
        let bundle = dist.appendingPathComponent("PromptMeet.app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let script = resources.appendingPathComponent("companion/backend/main_service.py")
        let python = resources.appendingPathComponent("companion/python/bin/python3")
        let environment = root.appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
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
