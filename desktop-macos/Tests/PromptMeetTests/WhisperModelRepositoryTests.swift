import Foundation
import XCTest
@testable import PromptMeet

final class WhisperModelRepositoryTests: XCTestCase {
    func testRepositoryCreatesPromptMeetModelDirectoryAndFindsOnlyBinFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WhisperModelRepository(modelsDirectory: root)

        try repository.prepareDirectory()
        try Data([1]).write(to: root.appendingPathComponent("ggml-small.bin"))
        try Data([2]).write(to: root.appendingPathComponent("partial.download"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(repository.installedModels().map(\.lastPathComponent), ["ggml-small.bin"])
    }

    func testCatalogIncludesFastAndLargeLocalChoices() {
        XCTAssertEqual(WhisperModelCatalog.models.first?.id, "tiny")
        XCTAssertTrue(WhisperModelCatalog.models.contains { $0.id == "large-v3-turbo-q5_0" })
        XCTAssertTrue(WhisperModelCatalog.models.contains { $0.id == "large-v3-turbo" })
        XCTAssertTrue(WhisperModelCatalog.models.allSatisfy { $0.downloadURL.scheme == "https" })
    }

    func testPreferencesPersistSelectedModelAndLanguage() throws {
        let suite = "PromptMeetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WhisperPreferences(defaults: defaults)

        preferences.selectedModelID = "small"
        preferences.language = "zh"

        let restored = WhisperPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedModelID, "small")
        XCTAssertEqual(restored.language, "zh")
    }

    func testAutomaticDetectionIsTheDefaultLanguageForNewInstall() throws {
        let suite = "PromptMeetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(WhisperPreferences(defaults: defaults).language, "auto")
    }

    func testTranslationPreferencesPersistTargetLanguage() throws {
        let suite = "PromptMeetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WhisperPreferences(defaults: defaults)

        preferences.translationEnabled = true
        preferences.translationTargetLanguage = "zh"

        let restored = WhisperPreferences(defaults: defaults)
        XCTAssertTrue(restored.translationEnabled)
        XCTAssertEqual(restored.translationTargetLanguage, "zh")
    }
}
