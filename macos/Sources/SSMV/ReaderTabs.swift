import AppKit
import MarkdownCore

/// A compact tab strip for the existing reader. Tabs retain controls, not document content.
@MainActor
final class ReaderTabs: NSView {
  var onSelect: ((UUID) -> Void)?
  var onClose: ((UUID) -> Void)?
  var onAdd: (() -> Void)?

  private let scroller = NSScrollView()
  private let strip = NSView()
  private let add = NSButton()
  private var tabs: [UUID: Tab] = [:]
  private var order: [UUID] = []
  private var selected: UUID?
  private var revealSelection = false
  private var previousViewportWidth: CGFloat = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityRole(.tabGroup)
    setAccessibilityLabel("Open documents")
    scroller.drawsBackground = false
    scroller.borderType = .noBorder
    scroller.hasHorizontalScroller = true
    scroller.autohidesScrollers = true
    scroller.scrollerStyle = .overlay
    scroller.horizontalScrollElasticity = .none
    scroller.verticalScrollElasticity = .none
    scroller.documentView = strip
    addSubview(scroller)
    add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    add.imagePosition = .imageOnly
    add.bezelStyle = .accessoryBarAction
    add.isBordered = false
    add.toolTip = "Open a document (⌘O)"
    add.setAccessibilityLabel("Open a document")
    add.target = self
    add.action = #selector(addDocument)
    addSubview(add)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
  @objc private func addDocument() { onAdd?() }

  func update(records: [DocumentRecord], selected: UUID?) {
    let ids = records.map(\.id)
    let changed = ids != order || self.selected != selected
    if ids != order {
      let retained = Set(ids)
      for id in order where !retained.contains(id) { tabs.removeValue(forKey: id)?.removeFromSuperview() }
    }
    var resized = false
    for record in records {
      let tab: Tab
      if let existing = tabs[record.id] { tab = existing }
      else {
        tab = Tab(id: record.id, owner: self)
        tabs[record.id] = tab
        strip.addSubview(tab)
      }
      if tab.configure(record: record, selected: selected == record.id) { resized = true }
    }
    order = ids
    self.selected = selected
    if changed || resized {
      revealSelection = true
      needsLayout = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: bounds.minY, width: bounds.width, height: 1).fill()
  }

  override func layout() {
    super.layout()
    let height = bounds.height
    add.frame = NSRect(x: max(0, bounds.width - 32), y: max(0, (height - 26) / 2), width: 28, height: 26)
    scroller.frame = NSRect(x: 4, y: 0, width: max(0, bounds.width - 39), height: height)
    var x: CGFloat = 0
    for id in order {
      guard let tab = tabs[id] else { continue }
      tab.frame = NSRect(x: x, y: max(0, (height - 26) / 2), width: tab.preferredWidth, height: 26)
      x += tab.frame.width + 2
    }
    strip.setFrameSize(NSSize(width: max(x, scroller.contentSize.width), height: height))
    if revealSelection || previousViewportWidth != scroller.contentSize.width {
      if let id = selected, let tab = tabs[id] { strip.scrollToVisible(tab.frame) }
      previousViewportWidth = scroller.contentSize.width
      revealSelection = false
    }
  }

  private final class Tab: NSView {
    let id: UUID
    weak var owner: ReaderTabs?
    let label = NSButton()
    let close = NSButton()
    private var active: Bool?
    private(set) var preferredWidth: CGFloat = 80

    init(id: UUID, owner: ReaderTabs) {
      self.id = id
      self.owner = owner
      super.init(frame: .zero)
      label.isBordered = false
      label.setButtonType(.momentaryPushIn)
      label.cell?.lineBreakMode = .byTruncatingTail
      label.target = self
      label.action = #selector(selectTab)
      label.setAccessibilityRole(.radioButton)
      addSubview(label)
      close.isBordered = false
      close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
      close.imagePosition = .imageOnly
      close.controlSize = .small
      close.target = self
      close.action = #selector(closeTab)
      addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectTab() { owner?.onSelect?(id) }
    @objc private func closeTab() { owner?.onClose?(id) }

    func configure(record: DocumentRecord, selected: Bool) -> Bool {
      switch record.source {
      case .localFile(let url): label.toolTip = url.path
      case .remote(let url): label.toolTip = url.absoluteString
      case .imported: label.toolTip = record.displayName
      }
      guard label.title != record.displayName || active != selected else { return false }
      active = selected
      label.title = record.displayName
      label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: selected ? .semibold : .regular)
      label.setAccessibilityLabel(record.displayName)
      label.setAccessibilityValue(NSNumber(value: selected))
      close.isHidden = !selected
      close.toolTip = "Close \(record.displayName)"
      close.setAccessibilityLabel("Close \(record.displayName)")
      preferredWidth = min(196, max(70, label.intrinsicContentSize.width + (selected ? 34 : 16)))
      needsLayout = true
      needsDisplay = true
      return true
    }
    override func layout() {
      super.layout()
      close.frame = NSRect(x: bounds.width - 24, y: 2, width: 22, height: bounds.height - 4)
      label.frame = NSRect(x: 4, y: 0, width: bounds.width - (close.isHidden ? 8 : 28), height: bounds.height)
    }
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      if active == true {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 5, yRadius: 5).fill()
      } else {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: bounds.maxX - 1, y: 5, width: 0.5, height: max(0, bounds.height - 10))).fill()
      }
    }
  }
}
