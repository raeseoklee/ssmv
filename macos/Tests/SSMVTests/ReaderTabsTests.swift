import AppKit
import MarkdownCore
import Testing
@testable import SSMV

@MainActor @Test func readerTabsRevealSelectedDocumentAndDispatchByIdentity() throws {
  _ = NSApplication.shared
  let tabs = ReaderTabs(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
  let records = (0..<12).map { index in
    DocumentRecord(source: .localFile(URL(fileURLWithPath: "/fixture/\(index).md")),
      displayName: "Document \(index).md", addedOrdinal: index)
  }
  func buttons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { (($0 as? NSButton).map { [$0] } ?? []) + buttons(in: $0) }
  }
  var selected: UUID?, closed: UUID?, added = false
  tabs.onSelect = { selected = $0 }; tabs.onClose = { closed = $0 }; tabs.onAdd = { added = true }
  tabs.update(records: records, selected: records[11].id)
  tabs.layoutSubtreeIfNeeded()
  let scroller = try #require(tabs.subviews.compactMap { $0 as? NSScrollView }.first)
  #expect(scroller.documentVisibleRect.minX > 0)
  let last = try #require(buttons(in: tabs).first { $0.title == records[11].displayName })
  let row = try #require(last.superview)
  #expect(scroller.documentVisibleRect.contains(row.frame))
  last.performClick(nil)
  let close = try #require(buttons(in: row).first { $0.toolTip == "Close Document 11.md" })
  #expect(!close.isHidden)
  close.performClick(nil)
  #expect(selected == records[11].id && closed == records[11].id)
  try #require(tabs.subviews.compactMap { $0 as? NSButton }.first).performClick(nil)
  #expect(added)
  tabs.update(records: Array(records.dropLast()), selected: records[0].id)
  tabs.layoutSubtreeIfNeeded()
  #expect(scroller.documentVisibleRect.minX == 0)
  #expect(!buttons(in: tabs).contains(where: { $0.title == "Document 11.md" }))
  #expect(buttons(in: tabs).filter { $0.toolTip?.hasPrefix("Close ") == true && !$0.isHidden }.count == 1)
}
