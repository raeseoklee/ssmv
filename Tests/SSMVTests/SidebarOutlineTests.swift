import AppKit
import MarkdownCore
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct SidebarOutlineTests {
  private func findOutline(in view: NSView) -> NSOutlineView? {
    if let table = view as? NSOutlineView { return table }
    return view.subviews.compactMap { findOutline(in: $0) }.first
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
  }

  @Test func headingsNestUnderFilesAndSelectByIdentity() async throws {
    _ = NSApplication.shared
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    let url = URL(fileURLWithPath: "/tmp/ssmv-outline-fixture.md")
    sidebar.update(urls: [url], selected: url)
    let table = try #require(findOutline(in: sidebar.view))
    let root = try #require(
      sidebar.outlineView(table, child: 0, ofItem: nil) as? SidebarController.Item)
    sidebar.provideDocument(
      try MarkdownDocument.parse("# Parent\n\n## Same\n\n### Child\n\n## Same"), for: url)
    try await waitUntil { root.loaded }
    #expect(root.children.first?.heading?.title == "Parent")
    let parent = try #require(root.children.first)
    #expect(parent.children.map { $0.heading?.id } == [1, 3])
    #expect(parent.children.first?.children.first?.heading?.title == "Child")
    table.expandItem(root)
    table.expandItem(parent)
    var selected: (URL, Int)?
    sidebar.onSelectHeading = { selected = ($0, $1) }
    let second = parent.children[1]
    table.selectRowIndexes(
      IndexSet(integer: table.row(forItem: second)), byExtendingSelection: false)
    sidebar.outlineViewSelectionDidChange(
      Notification(name: NSOutlineView.selectionDidChangeNotification))
    #expect(selected?.0 == url)
    #expect(selected?.1 == 3)
    sidebar.update(urls: [url], selected: url)
    #expect(table.isItemExpanded(parent))
    #expect((table.item(atRow: table.selectedRow) as? SidebarController.Item)?.heading?.id == 3)
    sidebar.setOutlineEnabled(false)
    #expect(table.numberOfRows == 1)
    #expect(root.children.isEmpty)
    #expect(sidebar.outlineView(table, numberOfChildrenOfItem: root) == 0)
  }

  @Test func abandonedLoadsFinishAndCompletionPreservesCollapse() async throws {
    _ = NSApplication.shared
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    let url = URL(fileURLWithPath: "/tmp/ssmv-outline-abandoned.md")
    sidebar.update(urls: [url], selected: url)
    let table = try #require(findOutline(in: sidebar.view))
    let root = try #require(
      sidebar.outlineView(table, child: 0, ofItem: nil) as? SidebarController.Item)
    sidebar.invalidateOutline(url)
    sidebar.finishPendingDocument(url, failed: true)
    #expect(root.children.first?.message == "Couldn’t read headings")
    #expect(!root.loaded)
    sidebar.invalidateOutline(url)
    sidebar.finishPendingDocument(url, failed: false)
    #expect(root.children.first?.message != "Loading headings…")
    sidebar.provideDocument(try MarkdownDocument.parse("# Ready"), for: url)
    table.expandItem(root)
    table.collapseItem(root)
    try await waitUntil { root.loaded }
    #expect(!table.isItemExpanded(root))
    #expect(root.children.first?.heading?.title == "Ready")
  }

  @Test func loadingOutlineAboveViewportKeepsVisibleFileInPlace() async throws {
    _ = NSApplication.shared
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
    let urls = (0..<20).map { URL(fileURLWithPath: "/tmp/ssmv-scroll-\($0).md") }
    sidebar.update(urls: urls, selected: urls.last)
    sidebar.view.layoutSubtreeIfNeeded()
    let table = try #require(findOutline(in: sidebar.view))
    let first = try #require(
      sidebar.outlineView(table, child: 0, ofItem: nil) as? SidebarController.Item)
    sidebar.provideDocument(try MarkdownDocument.parse("# Initial"), for: urls[0])
    try await waitUntil { first.loaded }
    table.expandItem(first)
    table.layoutSubtreeIfNeeded()
    let target = sidebar.outlineView(table, child: 10, ofItem: nil)
    let clip = try #require(table.enclosingScrollView?.contentView)
    clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: table.row(forItem: target)).minY))
    let before = table.rect(ofRow: table.row(forItem: target)).minY - clip.bounds.minY
    sidebar.provideDocument(
      try MarkdownDocument.parse((0..<30).map { "# Heading \($0)" }.joined(separator: "\n\n")),
      for: urls[0])
    try await waitUntil { first.children.count == 30 }
    let after = table.rect(ofRow: table.row(forItem: target)).minY - clip.bounds.minY
    #expect(abs(after - before) < 1)
  }

  @Test func expandingFilesKeepsDisplayedRootOrder() async throws {
    _ = NSApplication.shared
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    let urls = ["A", "B", "C", "D"].map { URL(fileURLWithPath: "/tmp/ssmv-order-\($0).md") }
    sidebar.update(urls: urls, selected: urls[0])
    let table = try #require(findOutline(in: sidebar.view))
    let roots = (0..<4).map {
      sidebar.outlineView(table, child: $0, ofItem: nil) as! SidebarController.Item
    }
    for index in [3, 1, 0, 2] {
      sidebar.provideDocument(try MarkdownDocument.parse("# Concurrent \(index)"), for: urls[index])
      table.expandItem(roots[index])
    }
    try await waitUntil { roots.allSatisfy(\.loaded) }
    #expect(
      (0..<table.numberOfRows).compactMap { row -> URL? in
        guard let item = table.item(atRow: row) as? SidebarController.Item, item.isFile else {
          return nil
        }
        return item.url
      } == urls)
    for index in [3, 1, 0, 2, 3, 0, 1, 2] {
      sidebar.invalidateOutline(urls[index])
      sidebar.provideDocument(
        try MarkdownDocument.parse("# Title\n\n## First\n\n## Second"), for: urls[index])
      table.expandItem(roots[index])
      try await waitUntil { roots[index].loaded }
      table.expandItem(roots[index], expandChildren: true)
      let displayed = (0..<table.numberOfRows).compactMap { row -> URL? in
        guard let item = table.item(atRow: row) as? SidebarController.Item, item.isFile else {
          return nil
        }
        return item.url
      }
      #expect(displayed == urls)
      for root in roots {
        let row = table.row(forItem: root)
        let cell = try #require(
          table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.stringValue == root.url.lastPathComponent)
      }
      table.collapseItem(roots[index])
    }
  }

  @Test func expandingInactiveFileLoadsLazilyAndRemovalDiscardsIt() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".md")
    try "# Lazy heading".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    sidebar.update(urls: [url], selected: nil)
    let table = try #require(findOutline(in: sidebar.view))
    let root = try #require(
      sidebar.outlineView(table, child: 0, ofItem: nil) as? SidebarController.Item)
    #expect(!root.loaded)
    table.expandItem(root)
    try await waitUntil { root.loaded }
    #expect(root.children.first?.heading?.title == "Lazy heading")
    sidebar.update(urls: [], selected: nil)
    #expect(table.numberOfRows == 0)
  }
}
