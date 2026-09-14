import AppKit
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct ExportLifecycleTests {
  private func withHiddenViewer(_ check: (AppDelegate, ViewerWindow) throws -> Void) rethrows {
    _ = NSApplication.shared
    let defaults = UserDefaults.standard
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var isolated = original
    isolated["legacyPreferencesMigrated"] = true
    isolated["documentShelf"] = Data()
    defaults.setVolatileDomain(isolated, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let owner = AppDelegate()
    let viewer = ViewerWindow(owner: owner)
    owner.windows.append(viewer)
    try check(owner, viewer)
  }

  @Test func closingExportStaysTrackedUntilCleanupCompletes() throws {
    try withHiddenViewer { owner, viewer in
      let window = try #require(viewer.window)
      #expect(!window.isVisible)
      viewer.exportJob = PDFExportJob()
      viewer.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))

      #expect(viewer.isClosing)
      #expect(viewer.hasPDFExport)
      // Quit must still discover this job while asynchronous cancellation cleans up.
      #expect(owner.windows.filter { $0.hasPDFExport }.contains { $0 === viewer })

      viewer.finishPDFExport(nil)
      #expect(!viewer.hasPDFExport)
      #expect(owner.windows.isEmpty)
      #expect(!window.isVisible)
    }
  }

  @Test func closingWithoutExportRemovesWindowImmediately() throws {
    try withHiddenViewer { owner, viewer in
      let window = try #require(viewer.window)
      viewer.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
      #expect(viewer.isClosing)
      #expect(owner.windows.isEmpty)
      #expect(!window.isVisible)
    }
  }
}
