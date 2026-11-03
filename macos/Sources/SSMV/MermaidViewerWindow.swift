import AppKit
import WebKit

/// The interactive browser exists only while this separate diagram window is open.
@MainActor
final class MermaidViewerWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
  WKScriptMessageHandler
{
  var onClose: (() -> Void)?
  private var browser: MermaidViewerWebView?
  private var loading: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var finished = false
  private let source: String
  private let dark: Bool
  private static let page = "ssmv-mermaid://bundle/viewer.html"

  init(source: String, appearance: NSAppearance?) {
    self.source = source
    dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Diagram — SSMV"
    window.minSize = NSSize(width: 520, height: 360)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.delegate = self
    window.center()
    guard source.utf8.count <= 65_536,
      let assets = Bundle.main.resourceURL?.appendingPathComponent("mermaid"),
      FileManager.default.fileExists(atPath: assets.appendingPathComponent("viewer.html").path)
    else { showError(); return }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(MermaidResourceHandler(root: assets), forURLScheme: "ssmv-mermaid")
    config.userContentController.add(self, name: "ssmvViewer")
    let web = MermaidViewerWebView(frame: window.contentView!.bounds, configuration: config)
    web.autoresizingMask = [.width, .height]
    web.navigationDelegate = self
    web.setAccessibilityLabel("Interactive diagram")
    window.contentView = web
    window.makeFirstResponder(web)
    browser = web
    web.load(URLRequest(url: URL(string: Self.page)!))
    loading = Task { @MainActor [weak self, weak web] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while !Task.isCancelled && ContinuousClock.now < deadline {
        guard let web else { return }
        if (try? await web.evaluateJavaScript("typeof window.ssmvOpenDiagram === 'function'")) as? Bool == true {
          guard !Task.isCancelled else { return }
          self?.render()
          return
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
      if !Task.isCancelled { self?.showError() }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func render() {
    guard let browser else { return }
    timeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      self?.showError()
    }
    browser.callAsyncJavaScript("return await window.ssmvOpenDiagram(source, dark);",
      arguments: ["source": source, "dark": dark], in: nil, in: .page) { [weak self] result in
      guard let self, !self.finished else { return }
      self.timeout?.cancel()
      self.timeout = nil
      if case .failure = result { self.showError() }
    }
  }

  private func releaseBrowser() {
    loading?.cancel(); loading = nil
    timeout?.cancel(); timeout = nil
    browser?.stopLoading()
    browser?.navigationDelegate = nil
    browser?.configuration.userContentController.removeScriptMessageHandler(forName: "ssmvViewer")
    browser?.removeFromSuperview()
    browser = nil
  }

  private func showError() {
    guard !finished else { return }
    finished = true
    releaseBrowser()
    let message = NSTextField(wrappingLabelWithString:
      "This diagram could not be opened. Close this window and try again. The document remains available in the reader.")
    message.frame = NSRect(x: 32, y: 32, width: 450, height: 80)
    let content = NSView(frame: window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1000, height: 720))
    content.addSubview(message)
    window?.contentView = content
  }

  func windowWillClose(_ notification: Notification) {
    finished = true
    releaseBrowser()
    let callback = onClose
    onClose = nil
    callback?()
  }

  func userContentController(_ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.absoluteString == Self.page,
      let action = (message.body as? [String: Any])?["action"] as? String else { return }
    if action == "fullscreen" { window?.toggleFullScreen(nil) }
    else if action == "close" { close() }
  }

  func windowDidEnterFullScreen(_ notification: Notification) { setFullScreen(true) }
  func windowDidExitFullScreen(_ notification: Notification) { setFullScreen(false) }
  private func setFullScreen(_ value: Bool) {
    browser?.evaluateJavaScript("window.ssmvSetFullscreen?.(\(value ? "true" : "false"))", completionHandler: nil)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.request.url?.absoluteString == Self.page ? .allow : .cancel)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError() }
}

/// Keep native Edit/View menu shortcuts routed to the focused diagram window.
@MainActor
private final class MermaidViewerWebView: WKWebView {
  @objc func performFindPanelAction(_ sender: Any?) {
    evaluateJavaScript("window.ssmvFocusSearch?.()", completionHandler: nil)
  }
  @objc func increaseSize(_ sender: Any?) { command("zoom-in") }
  @objc func decreaseSize(_ sender: Any?) { command("zoom-out") }
  @objc func resetSize(_ sender: Any?) { command("actual-size") }
  private func command(_ action: String) {
    evaluateJavaScript("window.ssmvViewerCommand?.('\(action)')", completionHandler: nil)
  }
}
