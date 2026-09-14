import AppKit
import PDFKit
import Testing

@testable import MarkdownCore

@MainActor
private func exportFixture(_ source: String, name: String) throws -> PDFDocument {
  _ = NSApplication.shared
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build/pdf-qa", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(name + ".pdf")
  try PDFExporter.export(MarkdownDocument.parse(source), title: name, to: url)
  return try #require(PDFDocument(url: url))
}

@Test @MainActor func pdfPaginatesWithoutDroppingText() throws {
  let source =
    "# Export verification\n\n"
    + (1...90).map {
      "## Section \($0)\n\nParagraph \($0): A document should remain readable across page boundaries. **Bold** and `code`.\n\n"
    }.joined() + "\nEND-OF-DOCUMENT"
  let pdf = try exportFixture(source, name: "multipage")
  #expect(pdf.pageCount > 1)
  let text = try #require(pdf.string)
  for index in 1...90 { #expect(text.contains("Paragraph \(index):")) }
  #expect(text.contains("END-OF-DOCUMENT"))
  let page = try #require(pdf.page(at: 0))
  #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 1)
  #expect(abs(page.bounds(for: .mediaBox).height - 841.89) < 1)
}

@Test @MainActor func pdfSupportsKoreanAndTableInDarkMode() throws {
  let original = NSApp?.appearance
  _ = NSApplication.shared
  NSApp.appearance = NSAppearance(named: .darkAqua)
  defer { NSApp.appearance = original }
  let pdf = try exportFixture(
    "# 한글 문서\n\n읽기 쉬운 PDF입니다.\n\n| 항목 | 값 |\n| --- | --- |\n| 이름 | SSMV |\n| 지원 | PDF 출력 |\n\n```swift\nlet answer = 42\nprint(answer)\n```\n",
    name: "korean-table")
  let text = try #require(pdf.string)
  #expect(text.contains("한글 문서"))
  #expect(text.contains("SSMV"))
  #expect(text.contains("print(answer)"))
}

@Test @MainActor func pdfExportsEmptyDocument() throws {
  let pdf = try exportFixture("", name: "empty")
  #expect(pdf.pageCount == 1)
}

@Test @MainActor func pdfRemovesLocalAndCustomSchemeLinks() throws {
  let source =
    "[web](https://example.com) [local](file:///private/example.md) [custom](vscode://example) [script](javascript:alert)"
  let text = PDFExporter.printableText(try MarkdownDocument.parse(source))
  var links: [URL] = []
  text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
    if let url = value as? URL { links.append(url) }
  }
  #expect(links == [URL(string: "https://example.com")!])
  let pdf = try exportFixture(source, name: "safe-links")
  for index in 0..<pdf.pageCount {
    for annotation in pdf.page(at: index)!.annotations {
      if let url = annotation.url {
        #expect(["http", "https", "mailto"].contains(url.scheme ?? ""))
      }
    }
  }
}
