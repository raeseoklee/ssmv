import Foundation

/// Serialize parsing so rapid document switches cannot accumulate simultaneous parsers.
public actor DocumentLoader {
  public static let shared = DocumentLoader()

  public func load(_ url: URL) throws -> AttributedString {
    try Task.checkCancellation()
    let document = try MarkdownDocument.parse(
      MarkdownDocument.read(url), baseURL: url.deletingLastPathComponent())
    try Task.checkCancellation()
    return document
  }
}
