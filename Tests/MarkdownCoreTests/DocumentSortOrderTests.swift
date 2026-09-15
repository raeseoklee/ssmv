import Foundation
import Testing

@testable import MarkdownCore

@Test func sortingKeepsOriginalShelfAndUsesNaturalNames() throws {
  let urls = ["note10.md", "note2.md", "Alpha.md"].map { URL(fileURLWithPath: "/tmp/\($0)") }
  var shelf = DocumentShelf()
  shelf.add(urls)
  #expect(DocumentSortOrder.name.sorted(shelf.urls) == [urls[2], urls[1], urls[0]])
  #expect(DocumentSortOrder.added.sorted(shelf.urls) == urls)
  #expect(shelf.selectedURL == urls[2])
  let restored = try JSONDecoder().decode(DocumentShelf.self, from: JSONEncoder().encode(shelf))
  #expect(restored.urls == urls)
}

@Test func modifiedSortReadsOnceAndKeepsTiesStable() {
  let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/\($0).md") }
  var reads: [URL] = []
  let result = DocumentSortOrder.modified.sorted(urls) { url in
    reads.append(url)
    return url == urls[0] ? nil : Date(timeIntervalSince1970: url == urls[2] ? 20 : 10)
  }
  #expect(reads == urls)
  #expect(result == [urls[2], urls[1], urls[3], urls[0]])
  #expect(
    DocumentSortOrder.name.sorted([urls[1], urls[0]]) { _ in
      Issue.record("Name sort must not read file metadata")
      return nil
    } == [urls[0], urls[1]])
}
