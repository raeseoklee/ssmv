import Foundation

extension NSAttributedString.Key {
  public static let documentHeadingID = NSAttributedString.Key("SSMVDocumentHeadingID")
}

/// Heading ordinals match rendered anchors and remain stable when the same source is parsed again.
public struct DocumentOutline: Sendable, Equatable {
  public struct Heading: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let level: Int
    public let parentID: Int?
  }

  public let headings: [Heading]
  public let isTruncated: Bool

  public static func build(
    _ markdown: AttributedString, maximumHeadings: Int = 2000
  ) throws -> DocumentOutline {
    var headings: [Heading] = []
    var ancestors: [(id: Int, level: Int)] = []
    var currentID: Int?
    var currentLevel = 0
    var currentTitle = ""
    let limit = max(0, maximumHeadings)

    func appendCurrent() {
      guard currentID != nil else { return }
      let id = headings.count
      while let last = ancestors.last, last.level >= currentLevel {
        ancestors.removeLast()
      }
      headings.append(
        Heading(
          id: id, title: currentTitle, level: currentLevel,
          parentID: ancestors.last?.id))
      ancestors.append((id, currentLevel))
    }

    for run in markdown.runs {
      try Task.checkCancellation()
      guard
        let component = run.presentationIntent?.components.first(where: {
          if case .header = $0.kind { return true }
          return false
        }), case .header(let level) = component.kind
      else { continue }
      if component.identity != currentID {
        appendCurrent()
        if headings.count >= limit {
          return DocumentOutline(headings: headings, isTruncated: true)
        }
        currentID = component.identity
        currentLevel = level
        currentTitle = ""
      }
      let remaining = 256 - currentTitle.count
      if remaining > 0 {
        currentTitle += String(markdown.characters[run.range].prefix(remaining))
      }
    }
    try Task.checkCancellation()
    appendCurrent()
    return DocumentOutline(headings: headings, isTruncated: false)
  }
}
