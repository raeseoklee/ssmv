import AppKit

@MainActor
public enum MarkdownRenderer {
  public static func render(_ markdown: AttributedString, size: CGFloat) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let state = RenderingState(size: size)
    for run in markdown.runs {
      autoreleasepool { state.append(run, from: markdown, to: result) }
    }
    return result
  }

  /// Delivers bounded batches without retaining an additional complete rendered document.
  public static func renderIncrementally(
    _ markdown: AttributedString, size: CGFloat,
    append: (NSAttributedString) -> Void
  ) async throws {
    let state = RenderingState(size: size)
    var runs = markdown.runs.makeIterator()
    var finished = false
    var pending: NSAttributedString?
    var pendingText: NSString?
    var offset = 0
    while !finished {
      try Task.checkCancellation()
      autoreleasepool {
        var chunk = NSMutableAttributedString()
        let start = ContinuousClock.now
        var count = 0
        while count < 1024 && start.duration(to: .now) < .milliseconds(8) {
          if pending == nil {
            guard let run = runs.next() else {
              finished = true
              break
            }
            state.append(run, from: markdown, to: chunk)
            // Ordinary runs append directly. Only oversized batches need a
            // retained remainder, avoiding a copy and substring for every run.
            if chunk.length > 16_384 {
              pending = chunk
              pendingText = chunk.string as NSString
              offset = 0
              chunk = NSMutableAttributedString()
            }
          }
          if let rendered = pending, let text = pendingText {
            let length = min(16_384, rendered.length - offset)
            let range = text.rangeOfComposedCharacterSequences(
              for: NSRange(location: offset, length: length))
            chunk.append(rendered.attributedSubstring(from: range))
            offset = NSMaxRange(range)
            if offset == rendered.length {
              pending = nil
              pendingText = nil
            }
          }
          count += 1
          if chunk.length >= 16_384 { break }
        }
        if chunk.length > 0 { append(chunk) }
      }
      // A short suspension lets AppKit process input and draw between batches.
      if !finished { try await Task.sleep(for: .milliseconds(1)) }
    }
    try Task.checkCancellation()
  }

  private final class RenderingState {
    let size: CGFloat
    var previousBlock: Int?
    var previousAttributes: [NSAttributedString.Key: Any]?
    var tables: [Int: NSTextTable] = [:]
    var currentCell: NSTextTableBlock?
    var currentCellIdentity: Int?
    var convertedFonts: [String: NSFont] = [:]

    init(size: CGFloat) { self.size = size }

    func append(
      _ run: AttributedString.Runs.Run, from markdown: AttributedString,
      to result: NSMutableAttributedString
    ) {
      let components = run.presentationIntent?.components ?? []
      let block = components.first?.identity
      let startsBlock = block != previousBlock
      if startsBlock, let previousAttributes {
        result.append(
          NSAttributedString(
            string: "\n", attributes: previousAttributes)
        )
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 5
      paragraph.paragraphSpacing = 12
      var font = NSFont.systemFont(ofSize: size)
      var color = NSColor.labelColor
      var background: NSColor?
      var prefix = ""
      var traits: NSFontTraitMask = []
      var inCode = false
      for component in components {
        switch component.kind {
        case .header(let level):
          font = .systemFont(ofSize: size + CGFloat(max(0, 7 - level)) * 3, weight: .bold)
          paragraph.paragraphSpacingBefore = 14
          paragraph.paragraphSpacing = 10
        case .codeBlock:
          font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
          background = .quaternaryLabelColor
          paragraph.lineSpacing = 3
          paragraph.paragraphSpacing = 0
          inCode = true
        case .blockQuote:
          color = .secondaryLabelColor
          paragraph.headIndent = 20
          paragraph.firstLineHeadIndent = 20
        case .listItem(let ordinal):
          let ordered = components.contains {
            if case .orderedList = $0.kind { return true }
            return false
          }
          prefix = ordered ? "\(ordinal).  " : "•  "
          let depth = components.filter {
            switch $0.kind {
            case .orderedList, .unorderedList: true
            default: false
            }
          }.count
          paragraph.firstLineHeadIndent = CGFloat(max(0, depth - 1)) * 20
          paragraph.headIndent = paragraph.firstLineHeadIndent + 24
          paragraph.paragraphSpacing = 6
        case .tableCell:
          font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        default: break
        }
      }
      if let tableComponent = components.first(where: {
        if case .table = $0.kind { return true }
        return false
      }), case .table(let columns) = tableComponent.kind {
        let table = tables[tableComponent.identity] ?? NSTextTable()
        table.numberOfColumns = columns.count
        table.collapsesBorders = true
        table.setValue(100, type: .percentageValueType, for: .width)
        tables[tableComponent.identity] = table
        var row = 0
        var column = 0
        for component in components {
          switch component.kind {
          case .tableRow(let index): row = index
          case .tableCell(let index): column = index
          case .tableHeaderRow: traits.insert(.boldFontMask)
          default: break
          }
        }
        // All inline runs in a cell must refer to the same native text block.
        let cellIdentity = components.first(where: {
          if case .tableCell = $0.kind { return true }
          return false
        })?.identity
        let cell: NSTextTableBlock
        if let currentCell, currentCellIdentity == cellIdentity {
          cell = currentCell
        } else {
          cell = NSTextTableBlock(
            table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
          cell.setWidth(8, type: .absoluteValueType, for: .padding)
          cell.setWidth(0.5, type: .absoluteValueType, for: .border)
          cell.setBorderColor(.separatorColor)
          currentCell = cell
          currentCellIdentity = cellIdentity
        }
        paragraph.textBlocks = [cell]
        paragraph.paragraphSpacing = 0
        if columns.indices.contains(column) {
          switch columns[column].alignment {
          case .center: paragraph.alignment = .center
          case .right: paragraph.alignment = .right
          default: paragraph.alignment = .left
          }
        }
        font = .systemFont(ofSize: size)
      }
      if let inline = run.inlinePresentationIntent {
        if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
        if inline.contains(.code) {
          font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
          background = .quaternaryLabelColor
        }
      }
      if !traits.isEmpty {
        let key = "\(font.fontName):\(font.pointSize):\(traits.rawValue)"
        if let cached = convertedFonts[key] {
          font = cached
        } else {
          font = NSFontManager.shared.convert(font, toHaveTrait: traits)
          if convertedFonts.count >= 32 { convertedFonts.removeAll(keepingCapacity: true) }
          convertedFonts[key] = font
        }
      }
      let paragraphStyle: NSParagraphStyle
      if !startsBlock, let previous = previousAttributes?[.paragraphStyle] as? NSParagraphStyle {
        paragraphStyle = previous
      } else {
        paragraphStyle = paragraph
      }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle,
      ]
      if let background { attributes[.backgroundColor] = background }
      if let link = run.link { attributes[.link] = link }
      if run.inlinePresentationIntent?.contains(.strikethrough) == true {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      var text = String(markdown.characters[run.range])
      if !inCode { text = text.replacingOccurrences(of: "\u{2028}", with: "\n") }
      if startsBlock { text = prefix + text }
      result.append(NSAttributedString(string: text, attributes: attributes))
      previousBlock = block
      previousAttributes = attributes
    }
  }
}
