import AppKit
import WebKit

/// Short-lived isolated web renderer; the document itself remains native text.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
  static let shared = MermaidRenderer()
  private let cache = NSCache<NSString, NSImage>()
  private override init() {
    super.init()
    cache.totalCostLimit = 24 * 1_024 * 1_024
    cache.countLimit = 24
  }

  func image(_ source: String, dark: Bool, width: CGFloat) async -> NSImage? {
    guard source.utf8.count <= 65_536, !Task.isCancelled else { return nil }
    let key = "\(dark):\(source)" as NSString
    let original: NSImage
    if let cached = cache.object(forKey: key) { original = cached }
    else {
      guard let assets = Bundle.main.resourceURL?.appendingPathComponent("mermaid"),
        FileManager.default.fileExists(atPath: assets.appendingPathComponent("index.html").path)
      else { return nil }
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.setURLSchemeHandler(MermaidResourceHandler(root: assets), forURLScheme: "ssmv-mermaid")
      let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
      web.navigationDelegate = self
      web.load(URLRequest(url: URL(string: "ssmv-mermaid://bundle/index.html")!))
      defer { web.stopLoading(); web.navigationDelegate = nil }
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while web.isLoading && ContinuousClock.now < deadline && !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard !Task.isCancelled, !web.isLoading else { return nil }
      do {
        while ContinuousClock.now < deadline && !Task.isCancelled {
          if (try? await web.evaluateJavaScript("typeof window.ssmvRender === 'function'")) as? Bool == true { break }
          try? await Task.sleep(for: .milliseconds(20))
        }
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let value = await render(web, source: source, dark: dark)
        guard !Task.isCancelled, let dimensions = value,
          dimensions.width > 0, dimensions.height > 0, dimensions.width <= 2048, dimensions.height <= 4096 else { return nil }
        let w = dimensions.width
        let h = dimensions.height
        web.setFrameSize(NSSize(width: w, height: h))
        // Let layout settle before native capture; unlike SVG-to-canvas this preserves math and HTML labels.
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = NSRect(x: 0, y: 0, width: w, height: h)
        let rasterScale = min(2, sqrt(Double(24 * 1_024 * 1_024) / (w * h * 4)))
        snapshot.snapshotWidth = NSNumber(value: w * rasterScale / (NSScreen.main?.backingScaleFactor ?? 2))
        let image = try await web.takeSnapshot(configuration: snapshot)
        image.size = NSSize(width: w, height: h)
        original = image
        cache.setObject(image, forKey: key, cost: Int(w * h * rasterScale * rasterScale * 4))
      } catch { return nil }
    }
    guard let image = original.copy() as? NSImage else { return nil }
    let factor = min(1, max(100, width) / image.size.width, 700 / image.size.height)
    image.size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
    return image
  }

  private func render(_ web: WKWebView, source: String, dark: Bool) async -> CGSize? {
    let pending = PendingRender()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<CGSize?, Never>) in
        pending.continuation = continuation
        guard !Task.isCancelled else { pending.finish(nil); return }
        pending.timeout = Task { @MainActor [weak web] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          web?.stopLoading()
          pending.finish(nil)
        }
        web.callAsyncJavaScript("return await window.ssmvRender(source, dark);",
          arguments: ["source": source, "dark": dark], in: nil, in: .page) { result in
          guard let data = try? result.get() as? [String: Any],
            let width = data["width"] as? Double, let height = data["height"] as? Double,
            width.isFinite, height.isFinite else { pending.finish(nil); return }
          pending.finish(CGSize(width: width, height: height))
        }
      }
    } onCancel: {
      Task { @MainActor [weak web] in web?.stopLoading(); pending.finish(nil) }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.request.url?.absoluteString == "ssmv-mermaid://bundle/index.html" ? .allow : .cancel)
  }
}

/// Serves only packaged renderer assets; custom origin permits ESM without file-origin exceptions.
@MainActor
private final class MermaidResourceHandler: NSObject, WKURLSchemeHandler {
  let root: URL
  init(root: URL) { self.root = root.resolvingSymlinksInPath() }
  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, url.host == "bundle" else {
      urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
    }
    let file = root.appendingPathComponent(url.path).resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
    }
    let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
      "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"]
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": types[file.pathExtension] ?? "application/octet-stream",
        "Access-Control-Allow-Origin": "*"])!
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
private final class PendingRender {
  var continuation: CheckedContinuation<CGSize?, Never>?
  var timeout: Task<Void, Never>?
  func finish(_ value: CGSize?) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    continuation.resume(returning: value)
  }
}
