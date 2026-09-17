import Foundation
import Testing

@testable import MarkdownCore

@Test func parsesMarkdownSemantics() throws {
  let document = try MarkdownDocument.parse(
    "# Heading\n\nA **bold** and *italic* [link](https://example.com).\n\n- One\n- Two\n\n```swift\nlet x = 1\n```\n"
  )
  #expect(
    document.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
  #expect(document.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
  #expect(document.runs.contains { $0.link?.absoluteString == "https://example.com" })
  #expect(
    document.runs.contains { run in
      run.presentationIntent?.components.contains {
        if case .header(level: 1) = $0.kind { true } else { false }
      } == true
    })
  #expect(String(document.characters).contains("let x = 1"))
}

@Test func readsUnicodeAndStripsBOM() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("\u{FEFF}# 안녕하세요 👋".utf8).write(to: url)
  #expect(try MarkdownDocument.read(url) == "# 안녕하세요 👋")
}

@Test func rejectsBinaryAndOversizedFiles() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data([0xff, 0xfe, 0xff]).write(to: url)
  #expect(throws: MarkdownDocument.ReadError.self) { try MarkdownDocument.read(url) }
  try Data(repeating: 65, count: MarkdownDocument.maximumBytes + 1).write(to: url)
  #expect(throws: MarkdownDocument.ReadError.self) { try MarkdownDocument.read(url) }
}

@Test func emptyDocumentIsValid() throws {
  #expect(try MarkdownDocument.parse("").characters.isEmpty)
}

@Test func rejectsDirectories() throws {
  #expect(throws: MarkdownDocument.ReadError.self) {
    try MarkdownDocument.read(FileManager.default.temporaryDirectory)
  }
}
