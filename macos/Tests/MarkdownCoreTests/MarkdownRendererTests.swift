import AppKit
import Testing

@testable import MarkdownCore

@Test @MainActor func keepsParagraphsAndListItemsSeparate() throws {
  let parsed = try MarkdownDocument.parse("# Title\n\nFirst **bold** paragraph.\n\n- One\n- Two")
  let result = MarkdownRenderer.render(parsed, size: 16)
  #expect(result.string == "Title\nFirst bold paragraph.\n•  One\n•  Two")
  let heading = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
  #expect((heading?.pointSize ?? 0) > 16)
}

@Test @MainActor func preservesCodeWhitespace() throws {
  let parsed = try MarkdownDocument.parse("```swift\nlet x = 1\n    print(x)\n```\n")
  let result = MarkdownRenderer.render(parsed, size: 16)
  #expect(result.string.contains("let x = 1\n    print(x)"))
  let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
  #expect(style?.paragraphSpacing == 0)
}

@Test @MainActor func rendersNativeTableCells() throws {
  let parsed = try MarkdownDocument.parse("| Name | Value |\n| --- | ---: |\n| Speed | Fast |\n")
  let result = MarkdownRenderer.render(parsed, size: 16)
  #expect(result.string.contains("Name\nValue\nSpeed\nFast"))
  let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
  let block = style?.textBlocks.first as? NSTextTableBlock
  #expect(block?.table.numberOfColumns == 2)
}

@Test @MainActor func retainsRelativeLinks() throws {
  let parsed = try MarkdownDocument.parse(
    "[Next](Next.md)", baseURL: URL(fileURLWithPath: "/tmp/docs/"))
  let result = MarkdownRenderer.render(parsed, size: 16)
  let link = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
  #expect(link?.path == "/tmp/docs/Next.md")
}

@Test @MainActor func sharesNativeCellAcrossInlineFormatting() throws {
  let parsed = try MarkdownDocument.parse("| Name |\n| --- |\n| Plain **bold** end |")
  let result = MarkdownRenderer.render(parsed, size: 16)
  let plain = (result.string as NSString).range(of: "Plain").location
  let bold = (result.string as NSString).range(of: "bold").location
  let first = result.attribute(.paragraphStyle, at: plain, effectiveRange: nil) as? NSParagraphStyle
  let second = result.attribute(.paragraphStyle, at: bold, effectiveRange: nil) as? NSParagraphStyle
  #expect(first?.textBlocks.first === second?.textBlocks.first)
}

@Test @MainActor func incrementalRenderingPreservesFormattingAcrossBatches() async throws {
  let source = String(
    repeating:
      "# Heading\n\nParagraph **bold** and [link](https://example.com).\n\n- First\n- Second\n\n",
    count: 200)
  let parsed = try MarkdownDocument.parse(source)
  let expected = MarkdownRenderer.render(parsed, size: 16)
  let actual = NSMutableAttributedString()
  var chunks = 0
  try await MarkdownRenderer.renderIncrementally(parsed, size: 16) {
    actual.append($0)
    chunks += 1
  }
  #expect(chunks > 1)
  #expect(actual.isEqual(to: expected))
}

@Test @MainActor func incrementalRenderingStopsAfterCancellation() async throws {
  let parsed = try MarkdownDocument.parse(String(repeating: "Paragraph **bold**.\n\n", count: 500))
  var chunks = 0
  let task = Task { @MainActor in
    try await MarkdownRenderer.renderIncrementally(parsed, size: 16) { _ in
      chunks += 1
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }
  do {
    try await task.value
    Issue.record("Expected cancellation")
  } catch is CancellationError {
    #expect(chunks == 1)
  }
}

@Test @MainActor func incrementalRenderingSplitsLongParagraphWithoutBreakingUnicode() async throws {
  let parsed = try MarkdownDocument.parse(String(repeating: "한글 👨‍👩‍👧‍👦 e\u{301} ", count: 5000))
  let expected = MarkdownRenderer.render(parsed, size: 16)
  let actual = NSMutableAttributedString()
  var chunks = 0
  try await MarkdownRenderer.renderIncrementally(parsed, size: 16) {
    actual.append($0)
    chunks += 1
    #expect(!$0.string.contains("\u{FFFD}"))
  }
  #expect(chunks > 1)
  #expect(actual.isEqual(to: expected))
}

@Test @MainActor func incrementalRenderingKeepsTableCellsAcrossChunks() async throws {
  let source =
    "| Name | Value |\n| --- | ---: |\n"
    + String(repeating: "| plain **bold** | 42 |\n", count: 1200)
  let parsed = try MarkdownDocument.parse(source)
  let actual = NSMutableAttributedString()
  var chunks = 0
  try await MarkdownRenderer.renderIncrementally(parsed, size: 16) {
    actual.append($0)
    chunks += 1
  }
  #expect(chunks > 1)
  #expect(actual.string == MarkdownRenderer.render(parsed, size: 16).string)
  let plain = (actual.string as NSString).range(of: "plain").location
  let bold = (actual.string as NSString).range(of: "bold").location
  let first = actual.attribute(.paragraphStyle, at: plain, effectiveRange: nil) as? NSParagraphStyle
  let second = actual.attribute(.paragraphStyle, at: bold, effectiveRange: nil) as? NSParagraphStyle
  #expect(first?.textBlocks.first === second?.textBlocks.first)
  let last =
    actual.attribute(.paragraphStyle, at: actual.length - 1, effectiveRange: nil)
    as? NSParagraphStyle
  let cell = last?.textBlocks.first as? NSTextTableBlock
  #expect(cell?.startingColumn == 1)
  #expect(cell?.startingRow == 1200)
  #expect(last?.alignment == .right)
}
