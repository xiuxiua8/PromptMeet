import Foundation
import XCTest

@testable import PromptMeet

final class AudioPackagingCompatibilityTests: XCTestCase {
  func testBundleDeclaresMicrophonePurposeWithoutExtraAudioEntitlements() throws {
    let resources = packageRoot.appendingPathComponent("Resources")
    let info = try propertyList(
      at: resources.appendingPathComponent("Info.plist")
    )
    let entitlements = try propertyList(
      at: resources.appendingPathComponent("PromptMeet.entitlements")
    )

    XCTAssertEqual(
      info["NSMicrophoneUsageDescription"] as? String,
      "PromptMeet 使用麦克风生成本地实时会议转写。"
    )
    XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
    XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.device.audio-input"])
  }

  func testDeploymentTargetSupportsAVAudioEngineVoiceProcessing() throws {
    let package = try String(
      contentsOf: packageRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(package.contains(".macOS(.v14)"))
  }

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func propertyList(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
  }
}
