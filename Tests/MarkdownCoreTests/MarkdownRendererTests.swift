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
