import AppKit
import Foundation
import WebKit

/// A rendered formula image plus the amount its baseline sits above the
/// image's bottom edge. The view shifts the image down by `baselineShift`
/// so the formula baseline aligns with the surrounding text baseline.
struct FormulaImage: Equatable {
    let image: NSImage
    let baselineShift: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// KaTeX asset locations, resolved in order: packaged app bundle, then the
/// repository Resources directory for `swift run` and `swift test`.
enum KaTeXAssets {
    static func directory() -> URL? {
        if let bundled = Bundle.main.url(forResource: "katex.min.js", withExtension: nil, subdirectory: "katex") {
            return bundled.deletingLastPathComponent()
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/katex")
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("katex.min.js").path) {
            return repo
        }
        return nil
    }
}

/// Renders LaTeX formula source to transparent images with the bundled
/// KaTeX distribution through one hidden WKWebView. Rendering is offline
/// (assets ship in the app bundle), asynchronous, and cached by content so
/// streaming answers only pay the render cost once per unique formula.
@MainActor
final class FormulaImageStore: ObservableObject {
    static let shared = FormulaImageStore()

    /// Bumped after each cache fill so observing views re-render.
    @Published private(set) var revision = 0

    private struct Key: Hashable {
        let content: String
        let display: Bool
        let fontSize: CGFloat
    }

    private var cache: [Key: FormulaImage?] = [:]
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var renderChain: Task<Void, Never>?
    private let renderPadding: CGFloat = 2

    /// Synchronous cache lookup, scheduling an async render when missing.
    /// Returns nil while rendering so callers can show a readable fallback.
    func image(content: String, display: Bool, baseFontSize: CGFloat) -> FormulaImage? {
        let key = Key(content: content, display: display, fontSize: baseFontSize)
        if let cached = cache[key] {
            return cached
        }
        scheduleRender(key: key)
        return nil
    }

    /// Renders a formula now and returns it (used by tests and pre-warmers).
    func render(content: String, display: Bool, baseFontSize: CGFloat) async -> FormulaImage? {
        let key = Key(content: content, display: display, fontSize: baseFontSize)
        if let cached = cache[key] {
            return cached
        }
        let rendered = await renderNow(key: key)
        cache[key] = rendered
        revision += 1
        return rendered
    }

    private func scheduleRender(key: Key) {
        guard cache[key] == nil else { return }
        let previous = renderChain
        renderChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let rendered = await self.renderNow(key: key)
            self.cache[key] = rendered
            self.revision += 1
        }
    }

    // MARK: - KaTeX web view

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        webView.setValue(false, forKey: "drawsBackground")
        // WKWebView.takeSnapshot requires the view to be hosted in a window;
        // park the window far offscreen so it never disturbs the user.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 60),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        hostWindow = window
        return webView
    }

    /// Inlines the KaTeX @font-face woff2 files as data URIs so rendering
    /// works fully offline without file-URL access to the bundle.
    private static func inlinedCSS(from assets: URL) throws -> String {
        var css = try String(contentsOf: assets.appendingPathComponent("katex.min.css"), encoding: .utf8)
        let fontsDirectory = assets.appendingPathComponent("fonts")
        let files = try FileManager.default.contentsOfDirectory(atPath: fontsDirectory.path)
            .filter { $0.hasSuffix(".woff2") }
        for file in files {
            let data = try Data(contentsOf: fontsDirectory.appendingPathComponent(file))
            let encoded = data.base64EncodedString()
            let token = "url(fonts/\(file))"
            let replacement = "url(data:font/woff2;base64,\(encoded))"
            css = css.replacingOccurrences(of: token, with: replacement)
            css = css.replacingOccurrences(of: token.replacingOccurrences(of: ".woff2", with: ".woff"), with: replacement)
        }
        return css
    }

    private func renderNow(key: Key) async -> FormulaImage? {
        guard let assets = KaTeXAssets.directory() else { return nil }
        let webView = self.webView ?? makeWebView()
        self.webView = webView

        let css: String
        let katexJS: String
        do {
            css = try Self.inlinedCSS(from: assets)
            katexJS = try String(contentsOf: assets.appendingPathComponent("katex.min.js"), encoding: .utf8)
        } catch {
            return nil
        }
        let html = """
        <!DOCTYPE html>
        <html><head>
        <style>\(css)</style>
        <script>\(katexJS.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
        </head><body style="margin:0;padding:0;background:transparent;color:#f5f5f5;">
        <div id="out" style="font-size:\(key.fontSize)pt;line-height:1.2;padding:\(renderPadding)px;"></div>
        </body></html>
        """
        if webView.url == nil {
            let waiter = WebViewLoadWaiter(webView: webView)
            await waiter.load(html: html)
            // The heavy inlined KaTeX page needs a settle pass before the
            // compositor can snapshot it; this runs once per web view.
            try? await Task.sleep(for: .milliseconds(1200))
        }

        let source = key.content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let script = """
        (function() {
          var out = document.getElementById('out');
          out.innerHTML = '';
          var wrap = document.createElement('div');
          // Fixed origin so both inline and display formulas crop identically.
          wrap.style.cssText = 'position:absolute;left:2px;top:2px;';
          wrap.innerHTML = katex.renderToString('\(source)', {displayMode: \(key.display), throwOnError: false});
          out.appendChild(wrap);
          var el = wrap.querySelector('.katex') || wrap.firstElementChild;
          var rect = el.getBoundingClientRect();
          var strut = wrap.querySelector('.katex-html .strut') || wrap.querySelector('.strut');
          var depth = 0;
          if (strut) {
            var va = strut.style.verticalAlign;
            if (va) { depth = -parseFloat(va) || 0; }
          }
          var hasError = !!wrap.querySelector('.katex-error');
          return JSON.stringify({x: rect.x, y: rect.y, w: rect.width, h: rect.height, depth: depth, err: hasError});
        })();
        """
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
            let data = json.data(using: .utf8),
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let width = info["w"] as? Double, width > 0,
            let height = info["h"] as? Double, height > 0 else {
            return nil
        }
        // KaTeX echoes unsupported input with a .katex-error span; degrade to
        // the readable source fallback instead of showing error styling.
        if info["err"] as? Bool ?? false { return nil }

        // Let the compositor produce a frame for the new content before
        // snapshotting; the web view renders asynchronously.
        try? await Task.sleep(for: .milliseconds(500))

        let x = info["x"] as? Double ?? 0
        let y = info["y"] as? Double ?? 0
        let depth = info["depth"] as? Double ?? 0
        // Snapshot at a generous fixed size: absolutely-positioned
        // fraction parts only composite when the view is large enough.
        webView.setFrameSize(NSSize(width: 400, height: 120))
        webView.setFrameOrigin(.zero)

        let snapshotImage = await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let snapshotImage,
            let snapshot = NSBitmapImageRep(data: snapshotImage.tiffRepresentation ?? Data()) else {
            return nil
        }
        // Crop the formula's own rect (with padding) out of the large frame.
        // Inline formulas sit at the padded page origin; display formulas
        // are centered, so the crop must follow the element's measured rect.
        let scale = CGFloat(snapshot.pixelsWide) / 400
        let cropRect = NSRect(
            x: max(0, x - renderPadding) * scale,
            y: max(0, y - renderPadding) * scale,
            width: (width + renderPadding * 2) * scale,
            height: (height + renderPadding * 2) * scale
        )
        guard let cgImage = snapshot.cgImage,
            let croppedCG = cgImage.cropping(to: cropRect) else { return nil }
        let cropped = NSBitmapImageRep(cgImage: croppedCG)
        let paddedWidth = max(1, width + renderPadding * 2)
        let paddedHeight = max(1, height + renderPadding * 2)
        let image = NSImage(size: NSSize(width: paddedWidth, height: paddedHeight))
        image.addRepresentation(cropped)
        return FormulaImage(
            image: image,
            baselineShift: depth + renderPadding,
            width: paddedWidth,
            height: paddedHeight
        )
    }
}

/// Bridges WKNavigationDelegate completion to the async load continuation.
private final class WebViewLoadWaiter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Never>?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}
