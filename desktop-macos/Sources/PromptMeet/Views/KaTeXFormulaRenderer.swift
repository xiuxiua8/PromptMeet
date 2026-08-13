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
/// KaTeX distribution through a pool of hidden WKWebViews. Rendering is
/// offline (assets ship in the app bundle), asynchronous, and cached by
/// content so streaming answers only pay the render cost once per unique
/// formula.
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

    private struct Worker {
        let webView: WKWebView
        let window: NSWindow
        var chain: Task<Void, Never>?
        var loaded = false
    }

    private var cache: [Key: FormulaImage?] = [:]
    private var workers: [Worker] = []
    private var nextWorker = 0
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
        while workers.isEmpty {
            workers.append(makeWorker())
        }
        let rendered = await renderNow(key: key, workerIndex: 0)
        cache[key] = rendered
        revision += 1
        return rendered
    }

    private func scheduleRender(key: Key) {
        guard cache[key] == nil else { return }
        // Round-robin across a small pool of web views so a multi-formula
        // answer renders in parallel instead of serially.
        let workerIndex = nextWorker
        nextWorker = (nextWorker + 1) % Self.workerCount
        while workers.count <= workerIndex {
            workers.append(makeWorker())
        }
        let previous = workers[workerIndex].chain
        workers[workerIndex].chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let rendered = await self.renderNow(key: key, workerIndex: workerIndex)
            self.cache[key] = rendered
            self.revision += 1
        }
    }

    /// The JS that renders one formula into a fixed-origin wrapper and
    /// reports its geometry and baseline depth.
    private func renderScript(source: String, display: Bool, fontSize: CGFloat) -> String {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        (function() {
          var out = document.getElementById('out');
          out.style.fontSize = '\(fontSize)pt';
          out.innerHTML = '';
          var wrap = document.createElement('div');
          // Fixed origin so both inline and display formulas crop identically.
          wrap.style.cssText = 'position:absolute;left:2px;top:2px;';
          wrap.innerHTML = katex.renderToString('\(escaped)', {displayMode: \(display), throwOnError: false});
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
    }

    /// The offline KaTeX page: inlined CSS and JS so no file access is needed.
    private func rendererHTML(css: String, katexJS: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <style>\(css)</style>
        <script>\(katexJS.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
        </head><body style="margin:0;padding:0;background:transparent;color:#f5f5f5;">
        <div id="out" style="line-height:1.2;padding:\(renderPadding)px;"></div>
        </body></html>
        """
    }

    // MARK: - KaTeX web views

    /// Concurrent render workers; a small pool keeps multi-formula answers fast.
    private static let workerCount = 4

    private func makeWorker() -> Worker {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        webView.setValue(false, forKey: "drawsBackground")
        // WKWebView.takeSnapshot requires the view to be hosted in a window;
        // park the window far offscreen so it never disturbs the user.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        return Worker(webView: webView, window: window)
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
            let legacyToken = token.replacingOccurrences(of: ".woff2", with: ".woff")
            css = css.replacingOccurrences(of: legacyToken, with: replacement)
        }
        return css
    }

    private func renderNow(key: Key, workerIndex: Int) async -> FormulaImage? {
        guard let assets = KaTeXAssets.directory() else { return nil }
        let webView = workers[workerIndex].webView

        let css: String
        let katexJS: String
        do {
            css = try Self.inlinedCSS(from: assets)
            katexJS = try String(contentsOf: assets.appendingPathComponent("katex.min.js"), encoding: .utf8)
        } catch {
            return nil
        }
        let html = rendererHTML(css: css, katexJS: katexJS)
        if !workers[workerIndex].loaded {
            let waiter = WebViewLoadWaiter(webView: webView)
            await waiter.load(html: html)
            // The heavy inlined KaTeX page needs a settle pass before the
            // compositor can snapshot it; this runs once per web view.
            try? await Task.sleep(for: .milliseconds(250))
            workers[workerIndex].loaded = true
        }

        let script = renderScript(source: key.content, display: key.display, fontSize: key.fontSize)
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
        try? await Task.sleep(for: .milliseconds(80))

        let originX = info["x"] as? Double ?? 0
        let originY = info["y"] as? Double ?? 0
        let depth = info["depth"] as? Double ?? 0
        guard let cropped = await snapshotFormula(
            webView: webView,
            contentRect: CGRect(x: originX, y: originY, width: width, height: height),
            depth: depth
        ) else { return nil }
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

    /// Snaps the web view at a generous size (absolutely-positioned fraction
    /// parts only composite then) and crops the formula's own rect out.
    private func snapshotFormula(
        webView: WKWebView,
        contentRect: CGRect,
        depth: CGFloat
    ) async -> NSBitmapImageRep? {
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
        let scale = CGFloat(snapshot.pixelsWide) / 400
        let cropRect = NSRect(
            x: max(0, contentRect.minX - renderPadding) * scale,
            y: max(0, contentRect.minY - renderPadding) * scale,
            width: (contentRect.width + renderPadding * 2) * scale,
            height: (contentRect.height + renderPadding * 2) * scale
        )
        guard let cgImage = snapshot.cgImage,
            let croppedCG = cgImage.cropping(to: cropRect) else { return nil }
        return NSBitmapImageRep(cgImage: croppedCG)
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
