import AppKit

@MainActor
public enum PDFExporter {
  static func printableText(_ document: AttributedString) -> NSAttributedString {
    let text = NSMutableAttributedString(
      attributedString: MarkdownRenderer.render(document, size: 12))
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      guard let value else { return }
      let link = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
      if !["https", "http", "mailto"].contains(link?.scheme?.lowercased() ?? "") {
        text.removeAttribute(.link, range: range)
      }
    }
    return text
  }

  public static func export(_ document: AttributedString, title: String, to url: URL) throws {
    // Publish only a completed PDF so a failed export preserves an existing destination.
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".ssmv-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let appearance = NSAppearance(named: .aqua)!
    var succeeded = false
    appearance.performAsCurrentDrawingAppearance {
      let info = NSPrintInfo(dictionary: [:])
      info.paperSize = NSSize(width: 595.28, height: 841.89)
      info.topMargin = 42
      info.bottomMargin = 42
      info.leftMargin = 42
      info.rightMargin = 42
      info.isHorizontallyCentered = false
      info.isVerticallyCentered = false
      info.horizontalPagination = .fit
      info.verticalPagination = .automatic
      info.jobDisposition = .save
      info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporaryURL

      let width = info.paperSize.width - info.leftMargin - info.rightMargin
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
      view.appearance = appearance
      view.isEditable = false
      view.isHorizontallyResizable = false
      view.isVerticallyResizable = true
      view.textContainerInset = .zero
      view.textContainer?.lineFragmentPadding = 0
      view.textContainer?.widthTracksTextView = true
      view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
      view.backgroundColor = .white
      view.textStorage?.setAttributedString(printableText(document))
      view.layoutManager?.ensureLayout(for: view.textContainer!)
      view.sizeToFit()
      // An empty Markdown file still exports as a valid single-page PDF.
      if view.frame.height < 1 { view.setFrameSize(NSSize(width: width, height: 1)) }
      let operation = NSPrintOperation(view: view, printInfo: info)
      operation.jobTitle = title
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
      succeeded = operation.run()
    }
    guard succeeded else { throw ExportError.failed }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
  }

  public enum ExportError: LocalizedError {
    case failed
    public var errorDescription: String? {
      "The PDF could not be saved. Check the destination folder and try again."
    }
  }
}
