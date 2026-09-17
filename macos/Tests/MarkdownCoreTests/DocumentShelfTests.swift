import Foundation
import Testing

@testable import MarkdownCore

@Test func shelfDeduplicatesAndSelectsLastAddition() {
  var shelf = DocumentShelf()
  shelf.add([
    URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.md"),
    URL(fileURLWithPath: "/tmp/./a.md"),
  ])
  #expect(shelf.urls.count == 2)
  #expect(shelf.selectedURL?.lastPathComponent == "a.md")
}

@Test func removalSelectsNeighborAndHandlesEmptyShelf() {
  var shelf = DocumentShelf()
  let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0).md") }
  shelf.add(urls)
  shelf.select(urls[1])
  shelf.removeSelected()
  #expect(shelf.urls == [urls[0], urls[2]])
  #expect(shelf.selectedURL == urls[2])
  shelf.removeSelected()
  #expect(shelf.selectedURL == urls[0])
  shelf.removeSelected()
  shelf.removeSelected()
  #expect(shelf.urls.isEmpty)
  #expect(shelf.selectedURL == nil)
}

@Test func shelfRestoresSelection() throws {
  var shelf = DocumentShelf()
  let first = URL(fileURLWithPath: "/tmp/a.md")
  shelf.add([first, URL(fileURLWithPath: "/tmp/b.md")])
  shelf.select(first)
  let restored = try JSONDecoder().decode(DocumentShelf.self, from: JSONEncoder().encode(shelf))
  #expect(restored == shelf)
}

@Test func removingReferenceKeepsFile() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
  try Data("# Keep me".utf8).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  var shelf = DocumentShelf()
  shelf.add([url])
  shelf.removeSelected()
  #expect(try String(contentsOf: url, encoding: .utf8) == "# Keep me")
}
