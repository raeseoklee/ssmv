import AppKit
import MarkdownCore
import PDFKit
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct DocumentInputTests {
  private func fixture() throws -> (DocumentStore, URL, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "SSMV.InputTests." + UUID().uuidString
    return (
      try DocumentStore(defaults: UserDefaults(suiteName: suite)!, directory: root), root, suite
    )
  }

  private func outline(_ view: NSView) -> NSOutlineView? {
    (view as? NSOutlineView) ?? view.subviews.compactMap { outline($0) }.first
  }

  @Test func importedSnapshotPreservesSourceAndHasNoLocalBase() async throws {
    let (store, directory, suite) = try fixture()
    defer {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let text = "\u{FEFF}# Result\r\n\r\nOriginal text.\r\n"
    let imported = try store.importText(text, title: "Review")
    let loader = DocumentInputLoader(store: store)
    let snapshot = try #require(try await loader.load(imported))
    #expect(snapshot.source == text)
    #expect(snapshot.baseURL == nil)
    #expect(!String(snapshot.document.characters).hasPrefix("\u{FEFF}"))
    try store.remove(imported.id)
    #expect(try Data(contentsOf: #require(store.fileURL(for: imported))) == Data(text.utf8))
  }

  @Test func remoteRestoreDoesNotFetchMissingCache() async throws {
    let (store, directory, suite) = try fixture()
    defer {
      try? FileManager.default.removeItem(at: directory)
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let remote = try store.addRemote(
      URL(string: "https://ssmv-invalid-\(UUID().uuidString).invalid/a.md")!)
    let result = try await DocumentInputLoader(store: store).load(remote, cachedOnly: true)
    #expect(result == nil)
    #expect(store.record(remote.id)?.lastFetchedAt == nil)
  }

  @Test func metadataRefreshAndSelectionDoNotReorderUntilRequested() throws {
    let sidebar = SidebarController()
    defer { sidebar.cancelAll() }
    var first = DocumentRecord(
      source: .remote(URL(string: "https://example.com/a.md")!), displayName: "A.md",
      addedOrdinal: 0)
    var second = DocumentRecord(
      source: .remote(URL(string: "https://example.com/b.md")!), displayName: "B.md",
      addedOrdinal: 1)
    sidebar.update(records: [first, second], selectedID: first.id)
    let table = try #require(outline(sidebar.view))
    sidebar.selectDocument(second.sidebarKey)
    #expect(
      (table.item(atRow: table.selectedRow) as? SidebarController.Item)?.url == second.sidebarKey)
    #expect((table.item(atRow: 0) as? SidebarController.Item)?.url == first.sidebarKey)
    first.sourceModifiedAt = Date(timeIntervalSince1970: 10)
    second.sourceModifiedAt = Date(timeIntervalSince1970: 20)
    sidebar.updateMetadata([first, second])
    #expect((table.item(atRow: 0) as? SidebarController.Item)?.url == first.sidebarKey)
    sidebar.setSortOrder(.modified)
    #expect((table.item(atRow: 0) as? SidebarController.Item)?.url == second.sidebarKey)
  }

  @Test func pdfHelperAcceptsRemoteAndAbsentBaseButRejectsActionSchemes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.md")
    try "# Snapshot\n\n[Guide](guide.md)".write(to: input, atomically: true, encoding: .utf8)
    for base in ["", "https://example.com/docs/"] {
      let output = directory.appendingPathComponent(UUID().uuidString + ".pdf")
      let args = [
        "SSMV", "--export-pdf", input.path, base, output.path, "Result",
        directory.appendingPathComponent("progress").path,
      ]
      #expect(runPDFExportHelper(args) == 0)
      #expect(try #require(PDFDocument(url: output)).pageCount == 1)
    }
    #expect(
      runPDFExportHelper([
        "SSMV", "--export-pdf", input.path, "ssmv://do", "/tmp/not-written.pdf", "Result",
        "/tmp/no-progress",
      ]) == 2)
  }
}
