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

  @Test func bulkRemovalRequiresExplicitConfirmation() {
    let alert = ViewerWindow.removeAllConfirmation(count: 4)
    #expect(alert.buttons.map(\.title) == ["Cancel", "Remove All"])
    #expect(alert.buttons[0].keyEquivalent == "\r")
    #expect(alert.buttons[1].hasDestructiveAction)
    #expect(alert.informativeText.contains("4"))
    #expect(alert.informativeText.contains("remain on disk"))
    withHiddenViewer { _, viewer in
      let item = NSMenuItem(
        title: "Remove All", action: #selector(ViewerWindow.confirmRemoveAllDocuments),
        keyEquivalent: "")
      #expect(!viewer.validateMenuItem(item))
    }
  }

  @Test func updateNoticeGuidesThroughHomebrewOnly() {
    let alert = AppDelegate.updateAlert(version: "0.3.0")
    #expect(alert.messageText == "SSMV 0.3.0 is available")
    #expect(alert.informativeText.contains("brew update\nbrew upgrade --cask raeseoklee/tap/ssmv"))
    #expect(alert.buttons.map(\.title) == ["Copy Commands", "Dismiss"])
  }

  @Test func fullScreenUsesNativeToolbarRevealWithoutChangingWindowedMode() throws {
    try withHiddenViewer { _, viewer in
      let window = try #require(viewer.window)
      let applicationOptions = NSApp.presentationOptions
      let proposed: NSApplication.PresentationOptions = [.fullScreen, .hideDock, .hideMenuBar]
      let result = viewer.window(window, willUseFullScreenPresentationOptions: proposed)
      #expect(result.contains([.fullScreen, .hideDock, .autoHideMenuBar, .autoHideToolbar]))
      #expect(!result.contains(.hideMenuBar))
      #expect(!result.contains(.autoHideDock))
      #expect(window.toolbar?.isVisible == true)
      #expect(NSApp.presentationOptions == applicationOptions)
      #expect(
        viewer.window(window, willUseFullScreenPresentationOptions: [.fullScreen])
          .contains(.autoHideDock))
    }
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
