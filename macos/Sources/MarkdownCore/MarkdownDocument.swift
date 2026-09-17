import Foundation

public enum MarkdownDocument {
  // Bound the amount of work before allocating and parsing a file.
  public static let maximumBytes = 16 * 1_024 * 1_024

  public static func read(_ url: URL, preservingBOM: Bool = false) throws -> String {
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw ReadError.notRegularFile
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw ReadError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw ReadError.invalidEncoding }
    return !preservingBOM && text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
  }

  public static func parse(_ source: String, baseURL: URL? = nil) throws -> AttributedString {
    try AttributedString(
      markdown: source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source,
      options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible),
      baseURL: baseURL
    )
  }

  public enum ReadError: LocalizedError {
    case tooLarge, invalidEncoding, notRegularFile
    public var errorDescription: String? {
      switch self {
      case .notRegularFile: "Only regular text files can be opened."
      case .tooLarge: "This document exceeds the 16 MB viewing limit."
      case .invalidEncoding: "This document is not UTF-8 text. Save it as UTF-8 and try again."
      }
    }
  }
}
