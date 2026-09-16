import AppKit
import MarkdownCore
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct DocumentFileDropTests {
  @MainActor final class Drag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight = NSSpringLoadingHighlight.none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL)
      -> [String]?
    {
      nil
    }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
      classes classArray: [AnyClass],
      searchOptions: [NSPasteboard.ReadingOptionKey: Any],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  @Test func windowDropOpensDocumentsAndChildViewsDoNotInterceptFiles() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "SSMV.DropTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let store = try DocumentStore(
      defaults: defaults, directory: root.appendingPathComponent("store"))
    let owner = AppDelegate(store: store)
    let viewer = ViewerWindow(owner: owner)
    let window = try #require(viewer.window as? DocumentDropWindow)
    defer {
      viewer.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let a = root.appendingPathComponent("한글 문서.MD")
    let b = root.appendingPathComponent("B.markdown")
    let ignored = root.appendingPathComponent("ignored.txt")
    let folder = root.appendingPathComponent("folder.md")
    for url in [a, b, ignored] {
      try "# Original\n".write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let drag = Drag()
    defer { drag.draggingPasteboard.releaseGlobally() }
    drag.draggingDestinationWindow = window
    drag.draggingPasteboard.writeObjects([a, ignored, folder, b].map { $0 as NSURL })
    let views = descendants(try #require(window.contentView))
    let reader = try #require(views.compactMap { $0 as? NSTextView }.first)
    #expect(!reader.isEditable)
    #expect(reader.registeredDraggedTypes.isEmpty)
    #expect(window.draggingEntered(drag) == .copy)
    #expect(drag.numberOfValidItemsForDrop == 2)
    #expect(window.prepareForDragOperation(drag))
    #expect(window.performDragOperation(drag))
    #expect(store.records.map(\.source) == [.localFile(a), .localFile(b)])
    #expect(store.selectedRecord?.source == .localFile(b))
    let table = try #require(views.compactMap { $0 as? NSOutlineView }.first)
    #expect(table.registeredDraggedTypes.isEmpty)
    // Repeated drops through the shared window entry point select existing records.
    #expect(window.performDragOperation(drag))
    #expect(store.records.count == 2)
    let deadline = Date().addingTimeInterval(3)
    while !reader.string.contains("Original") && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reader.string.contains("Original"))
    for url in [a, b] { #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n") }
  }

  @Test func rejectsTextURLsUnsupportedFilesAndMoveOnlyDrags() throws {
    _ = NSApplication.shared
    let drag = Drag()
    defer { drag.draggingPasteboard.releaseGlobally() }
    let window = DocumentDropWindow(
      contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var delivered = false
    window.onDrop = { _ in delivered = true }
    for value in [
      "https://example.com/test.md", "file:///tmp/not-a-real-document.md", "# Markdown",
    ] {
      drag.draggingPasteboard.clearContents()
      drag.draggingPasteboard.setString(value, forType: .string)
      #expect(window.draggingEntered(drag).isEmpty)
      #expect(!window.performDragOperation(drag))
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".md")
    try "# Valid".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    drag.draggingPasteboard.clearContents()
    drag.draggingPasteboard.writeObjects([file as NSURL])
    #expect(window.draggingEntered(drag) == .copy)
    drag.draggingSourceOperationMask = .move
    #expect(window.draggingUpdated(drag).isEmpty)
    #expect(!window.prepareForDragOperation(drag))
    #expect(!delivered)
  }
}
