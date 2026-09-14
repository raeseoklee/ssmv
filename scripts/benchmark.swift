import AppKit
import Foundation

@main
struct Benchmark {
  @MainActor static func main() throws {
    // Reports parser + attributed-text construction, not launch time or screen layout.
    for count in [10, 100, 1_000] {
      let source = String(
        repeating:
          "## Heading\n\nA paragraph with **bold**, *italic*, and `code`.\n\n- First item\n- Second item\n\n",
        count: count)
      let start = ContinuousClock.now
      let parsed = try MarkdownDocument.parse(source)
      let parseTime = start.duration(to: .now)
      let renderStart = ContinuousClock.now
      let output = MarkdownRenderer.render(parsed, size: 16)
      let renderTime = renderStart.duration(to: .now)
      print(
        "bytes=\(source.utf8.count) parse=\(parseTime) render=\(renderTime) characters=\(output.length)"
      )
    }
  }
}
