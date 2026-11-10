import Foundation
import MarkdownCore
import Testing
@testable import SSMV

private actor SearchResults {
  var hits: [DocumentSearchHit] = []
  func store(_ value: [DocumentSearchHit]) { hits = value }
}

@Test func searchesShelfNamesAndBodiesWithNamesFirst() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let body = root.appendingPathComponent("Draft.md")
  try "한글 Example 세부 사항".write(to: body, atomically: true, encoding: .utf8)
  let bodyRecord = DocumentRecord(source: .imported(relativePath: "Draft.md"), displayName: "Draft", addedOrdinal: 1)
  let missing = root.appendingPathComponent("Example.md")
  let nameRecord = DocumentRecord(source: .localFile(missing), displayName: "Example.md", addedOrdinal: 2)
  let results = SearchResults()
  let entries = [DocumentSearchEntry(record: bodyRecord, file: body, location: "Imported"),
    DocumentSearchEntry(record: nameRecord, file: missing, location: "Documents")]
  try await DocumentSearch.run(entries, query: "example", remote: RemoteDocumentLoader(cacheDirectory: root)) {
    hits, _ in await results.store(hits)
  }
  let hits = await results.hits
  #expect(hits.map(\.id) == [nameRecord.id, bodyRecord.id])
  #expect(hits.last?.detail == "한글 Example 세부 사항")
}
