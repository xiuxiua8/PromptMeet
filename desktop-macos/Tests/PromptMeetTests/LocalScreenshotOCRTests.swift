import AppKit
import XCTest

@testable import PromptMeet

final class LocalScreenshotOCRTests: XCTestCase {
    func testRecognizesSyntheticNonPrivateChineseScreenshot() async throws {
        let pngData = try syntheticScreenshot(
            text: "截图证据：青岚计划在 14:30 部署，负责人周岚。"
        )

        let recognized = try await LocalScreenshotOCR().recognize(pngData)

        let text = try XCTUnwrap(recognized)
        XCTAssertTrue(text.contains("青岚"), text)
        XCTAssertTrue(text.contains("14:30"), text)
        XCTAssertTrue(text.contains("周岚"), text)
    }

    private func syntheticScreenshot(text: String) throws -> Data {
        let size = NSSize(width: 1_200, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        NSString(string: text).draw(
            in: NSRect(x: 40, y: 80, width: 1_120, height: 80),
            withAttributes: attributes
        )
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
