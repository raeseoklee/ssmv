import AppKit
import Testing

@testable import MarkdownCore

@Test func outlineCombinesInlineRunsAndPreservesHierarchy() throws {
  let parsed = try MarkdownDocument.parse(
    "# 첫 **제목** 👩🏽‍💻\n\n### Child [link](https://example.com)\n\n## Sibling\n\n# 첫 제목 👩🏽‍💻")
  let outline = try DocumentOutline.build(parsed)
  #expect(outline.headings.map(\.title) == ["첫 제목 👩🏽‍💻", "Child link", "Sibling", "첫 제목 👩🏽‍💻"])
  #expect(outline.headings.map(\.level) == [1, 3, 2, 1])
  #expect(
    outline.headings.map(\.parentID) == [nil, outline.headings[0].id, outline.headings[0].id, nil])
  #expect(Set(outline.headings.map(\.id)).count == 4)
  #expect(!outline.isTruncated)
}

@Test func outlineHandlesSetextAndIgnoresCode() throws {
  let parsed = try MarkdownDocument.parse(
    "Title\n=====\n\nSubtitle\n--------\n\n```markdown\n# Not a heading\n```\n\n    # Also code\n\nPlain text"
  )
  let outline = try DocumentOutline.build(parsed)
  #expect(outline.headings.map(\.title) == ["Title", "Subtitle"])
  #expect(outline.headings.map(\.level) == [1, 2])
}

@Test func outlineBoundsHeadingCountWithoutTruncatingFinalInlineRuns() throws {
  let parsed = try MarkdownDocument.parse("# One **bold**\n\n## Two *italic*\n\n### Three")
  let outline = try DocumentOutline.build(parsed, maximumHeadings: 2)
  #expect(outline.headings.map(\.title) == ["One bold", "Two italic"])
  #expect(outline.isTruncated)
  #expect(try !DocumentOutline.build(parsed, maximumHeadings: 3).isTruncated)
  #expect(try DocumentOutline.build(parsed, maximumHeadings: 0).headings.isEmpty)
  #expect(try DocumentOutline.build(MarkdownDocument.parse("Plain")).headings.isEmpty)
}

@Test @MainActor func outlineAnchorsDistinguishRepeatedTitlesInBothRenderers() async throws {
  let parsed = try MarkdownDocument.parse("# Same **title**\n\nBody\n\n## Same **title**")
  let outline = try DocumentOutline.build(parsed)
  let rendered = MarkdownRenderer.render(parsed, size: 16)
  let streamed = NSMutableAttributedString()
  try await MarkdownRenderer.renderIncrementally(parsed, size: 16) { streamed.append($0) }
  for text in [rendered, streamed] {
    var positions: [Int] = []
    for heading in outline.headings {
      var found: Int?
      text.enumerateAttribute(.documentHeadingID, in: NSRange(location: 0, length: text.length)) {
        value, range, stop in
        if value as? Int == heading.id {
          found = range.location
          stop.pointee = true
        }
      }
      positions.append(try #require(found))
    }
    #expect(positions == [0, 16])
    #expect(text.attribute(.documentHeadingID, at: 11, effectiveRange: nil) == nil)
  }
}

@Test func outlineHonorsCancellation() async throws {
  let parsed = try MarkdownDocument.parse("# Heading")
  let task = Task.detached {
    withUnsafeCurrentTask { $0?.cancel() }
    return try DocumentOutline.build(parsed)
  }
  do {
    _ = try await task.value
    Issue.record("Expected cancellation")
  } catch is CancellationError {
  }
}

@Test @MainActor func outlineIDsSurviveFreshParsingAndTitlesAreBounded() throws {
  let source = "# " + String(repeating: "👩🏽‍💻", count: 300) + "\n\n## Second"
  let outline = try DocumentOutline.build(MarkdownDocument.parse(source))
  #expect(outline.headings[0].title.count == 256)
  #expect(outline.headings.map(\.id) == [0, 1])
  let rendered = MarkdownRenderer.render(try MarkdownDocument.parse(source), size: 16)
  let second = (rendered.string as NSString).range(of: "Second")
  #expect(
    rendered.attribute(.documentHeadingID, at: second.location, effectiveRange: nil) as? Int == 1)
}
