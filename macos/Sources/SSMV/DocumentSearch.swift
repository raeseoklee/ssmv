import Foundation
import MarkdownCore

struct DocumentSearchEntry: Sendable {
  let record: DocumentRecord
  let file: URL?
  let location: String
}

struct DocumentSearchHit: Sendable {
  let id: UUID
  let name: String
  let detail: String
}

enum DocumentSearch {
  /// Invoked from the search task, never during drawing or when opening the reader.
  static func run(
    _ entries: [DocumentSearchEntry], query: String, remote: RemoteDocumentLoader,
    deliver: @Sendable ([DocumentSearchHit], Bool) async -> Void
  ) async throws {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    var hits: [DocumentSearchHit] = []
    var remaining: [DocumentSearchEntry] = []
    for entry in entries {
      try Task.checkCancellation()
      if term.isEmpty || entry.record.displayName.range(of: term, options: options) != nil {
        hits.append(.init(id: entry.record.id, name: entry.record.displayName, detail: entry.location))
      } else {
        remaining.append(entry)
      }
    }
    if !remaining.isEmpty { await deliver(hits, true) }
    var last = ContinuousClock.now
    for entry in remaining {
      try Task.checkCancellation()
      let body: String?
      if let file = entry.file {
        body = try? MarkdownDocument.read(file)
      } else if case .remote(let url) = entry.record.source {
        body = try? await remote.cached(url)?.source
      } else { body = nil }
      guard let body, let match = body.range(of: term, options: options) else { continue }
      let start = body.index(match.lowerBound, offsetBy: -24, limitedBy: body.startIndex) ?? body.startIndex
      let end = body.index(match.upperBound, offsetBy: 48, limitedBy: body.endIndex) ?? body.endIndex
      let excerpt = body[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      hits.append(.init(id: entry.record.id, name: entry.record.displayName, detail: excerpt))
      if last.duration(to: .now) >= .milliseconds(150) {
        await deliver(hits, true)
        last = .now
      }
    }
    try Task.checkCancellation()
    await deliver(hits, false)
  }
}
