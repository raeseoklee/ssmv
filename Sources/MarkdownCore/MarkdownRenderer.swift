import AppKit

@MainActor
public enum MarkdownRenderer {
  public static func render(_ markdown: AttributedString, size: CGFloat) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var previousBlock: Int?
    var tables: [Int: NSTextTable] = [:]
    for run in markdown.runs {
      let components = run.presentationIntent?.components ?? []
      let block = components.first?.identity
      let startsBlock = block != previousBlock
      if startsBlock && result.length > 0 {
        result.append(
          NSAttributedString(
            string: "\n", attributes: result.attributes(at: result.length - 1, effectiveRange: nil))
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
        let cell = NSTextTableBlock(
          table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setWidth(8, type: .absoluteValueType, for: .padding)
        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
        cell.setBorderColor(.separatorColor)
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
      if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
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
    }
    return result
  }
}
