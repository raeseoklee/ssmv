import AppKit
import MarkdownCore
import Testing

@testable import SSMV

@Test @MainActor func workspaceTabsNavigateOneReaderWithoutDeletingFiles() async throws {
  _ = NSApplication.shared
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let suite = "SSMV.WorkspaceTests." + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  let store = try DocumentStore(defaults: defaults, directory: root.appendingPathComponent("store"))
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let names = ["Welcome.md", "Release Notes.md", "Diagrams.md"]
  let urls = names.map { root.appendingPathComponent($0) }
  for (i, url) in urls.enumerated() {
    try ("# " + names[i].replacingOccurrences(of: ".md", with: "") +
      "\n\n## Reading workspace\n\nBrowse files and headings in the sidebar, then switch documents using the tabs above.\n\n## Diagram previews\n\nThe reader displays text first so you can keep reading while diagrams load.").write(to: url, atomically: true, encoding: .utf8)
  }
  try store.addLocal(urls)
  let owner = AppDelegate(store: store)
  let viewer = ViewerWindow(owner: owner)
  defer { viewer.close() }
  let window = try #require(viewer.window)
  if ProcessInfo.processInfo.environment["SSMV_WORKSPACE_DARK"] == "1" {
    window.appearance = NSAppearance(named: .darkAqua)
  }
  window.setContentSize(NSSize(width: 1250, height: 720))
  let content = try #require(window.contentView)
  content.layoutSubtreeIfNeeded()
  func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
  let views = all(content)
  let tabs = try #require(views.compactMap { $0 as? ReaderTabs }.first)
  let text = try #require(views.compactMap { $0 as? ReadingColumnTextView }.first)
  #expect(views.compactMap { $0 as? ReadingColumnTextView }.count == 1)
  let selected = store.records[1].id
  tabs.onSelect?(selected)
  let limit = ContinuousClock.now.advanced(by: .seconds(3))
  while !text.string.contains("Reading workspace"), ContinuousClock.now < limit {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(text.string.hasPrefix("Release Notes"))
  #expect(text.bounds.width - 2 * text.textContainerInset.width <= 762)
  if let path = ProcessInfo.processInfo.environment["SSMV_WORKSPACE_CAPTURE"],
    let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
    content.cacheDisplay(in: content.bounds, to: rep)
    let finalImage = NSImage(size: content.bounds.size)
    finalImage.lockFocus()
    window.backgroundColor.setFill()
    content.bounds.fill()
    rep.draw(in: content.bounds)
    finalImage.unlockFocus()
    let composed = try #require(finalImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    try composed.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
  tabs.onClose?(selected)
  #expect(store.record(selected) == nil)
  #expect(FileManager.default.fileExists(atPath: urls[1].path))
}
