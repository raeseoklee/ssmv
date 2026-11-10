import AppKit

@MainActor
final class DocumentSearchPanel: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
  var onQuery: ((String) -> Void)?
  var onSelect: ((UUID) -> Void)?
  var onDismiss: (() -> Void)?

  private let field = NSSearchField()
  private let status = NSTextField(labelWithString: "")
  private let table = SearchResultsTable()
  private var hits: [DocumentSearchHit] = []
  private var searching = false

  override func loadView() {
    preferredContentSize = NSSize(width: 360, height: 320)
    let content = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
    field.placeholderString = "Search documents"
    field.setAccessibilityLabel("Search documents")
    field.sendsSearchStringImmediately = true
    field.delegate = self
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    status.textColor = .secondaryLabelColor
    table.headerView = nil
    table.rowHeight = 42
    table.intercellSpacing = .zero
    table.allowsMultipleSelection = false
    table.selectionHighlightStyle = .regular
    table.setAccessibilityLabel("Document search results")
    let column = NSTableColumn(identifier: .init("result"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(openClickedResult)
    table.onEnter = { [weak self] in self?.openSelectedResult() }
    table.onEscape = { [weak self] in self?.onDismiss?() }
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    for item in [field, status, scroll] {
      item.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(item)
    }
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
      field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      field.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
      status.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
      status.trailingAnchor.constraint(equalTo: field.trailingAnchor),
      status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 7),
      scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    view = content
    update(hits, searching: searching)
  }

  func focusSearch() {
    _ = view
    view.window?.makeFirstResponder(field)
    field.selectText(nil)
  }

  func update(_ hits: [DocumentSearchHit], searching: Bool) {
    let previous = self.hits.indices.contains(table.selectedRow) ? self.hits[table.selectedRow].id : nil
    self.hits = hits
    self.searching = searching
    guard isViewLoaded else { return }
    table.reloadData()
    if !hits.isEmpty {
      let row = previous.flatMap { id in hits.firstIndex { $0.id == id } } ?? 0
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table.scrollRowToVisible(row)
    }
    refreshStatus()
  }

  private func refreshStatus() {
    if searching { status.stringValue = "Searching…" }
    else if hits.isEmpty { status.stringValue = field.stringValue.isEmpty ? "No open documents" : "No matches" }
    else { status.stringValue = "\(hits.count) " + (hits.count == 1 ? "document" : "documents") }
  }

  func controlTextDidChange(_ notification: Notification) { onQuery?(field.stringValue) }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)): moveSelection(1)
    case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
    case #selector(NSResponder.insertNewline(_:)): openSelectedResult()
    case #selector(NSResponder.cancelOperation(_:)): onDismiss?()
    default: return false
    }
    return true
  }

  private func moveSelection(_ offset: Int) {
    guard !hits.isEmpty else { return }
    let row = max(0, min(hits.count - 1, table.selectedRow + offset))
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }
  @objc private func openClickedResult() {
    if hits.indices.contains(table.clickedRow) { onSelect?(hits[table.clickedRow].id) }
  }
  private func openSelectedResult() {
    let row = table.selectedRow
    if hits.indices.contains(row) { onSelect?(hits[row].id) }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard hits.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("DocumentSearchResult")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell ?? ResultCell()
    cell.identifier = identifier
    cell.name.stringValue = hits[row].name
    cell.detail.stringValue = hits[row].detail
    cell.toolTip = hits[row].detail
    return cell
  }

  private final class SearchResultsTable: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 36, 76: onEnter?()
      case 53: onEscape?()
      default: super.keyDown(with: event)
      }
    }
  }

  private final class ResultCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
      detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      detail.textColor = .secondaryLabelColor
      for item in [name, detail] {
        item.lineBreakMode = .byTruncatingTail
        item.maximumNumberOfLines = 1
        item.translatesAutoresizingMaskIntoConstraints = false
        addSubview(item)
        NSLayoutConstraint.activate([
          item.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
          item.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
      }
      NSLayoutConstraint.activate([
        name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
      ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  }
}
