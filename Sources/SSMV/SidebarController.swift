import AppKit

@MainActor
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  var onSelect: ((URL) -> Void)?
  var onAdd: (() -> Void)?
  var onDrop: (([URL]) -> Void)?
  var onRemove: (() -> Void)?
  private let table = NSTableView()
  private let removeButton = NSButton()
  private var urls: [URL] = []
  private var updating = false

  override func loadView() {
    view = NSView()
    let title = NSTextField(labelWithString: "Documents")
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .secondaryLabelColor
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Document")))
    table.headerView = nil
    table.style = .sourceList
    table.rowHeight = 46
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Documents sidebar")
    table.registerForDraggedTypes([.fileURL])
    let contextMenu = NSMenu()
    let removeItem = contextMenu.addItem(
      withTitle: "Remove from Sidebar", action: #selector(removeClickedDocument), keyEquivalent: "")
    removeItem.target = self
    table.menu = contextMenu
    scroll.documentView = table
    let addButton = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add documents")!,
      target: self, action: #selector(addDocuments))
    addButton.bezelStyle = .inline
    addButton.toolTip = "Add documents (⌘O)"
    removeButton.image = NSImage(
      systemSymbolName: "minus", accessibilityDescription: "Remove document from sidebar")
    removeButton.target = self
    removeButton.action = #selector(removeDocument)
    removeButton.bezelStyle = .inline
    removeButton.toolTip = "Remove from sidebar; keep file on disk"
    let footer = NSStackView(views: [addButton, removeButton])
    footer.spacing = 12
    for subview in [title, scroll, footer] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
      title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
    ])
  }

  func update(urls: [URL], selected: URL?) {
    _ = view
    updating = true
    self.urls = urls
    table.reloadData()
    if let selected, let index = urls.firstIndex(of: selected) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
    } else {
      table.deselectAll(nil)
    }
    removeButton.isEnabled = selected != nil
    updating = false
  }

  func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let url = urls[row]
    let cell = NSTableCellView()
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
    icon.contentTintColor = .secondaryLabelColor
    let name = NSTextField(labelWithString: url.lastPathComponent)
    name.lineBreakMode = .byTruncatingMiddle
    let path = NSTextField(labelWithString: url.deletingLastPathComponent().path)
    path.font = .systemFont(ofSize: 10)
    path.textColor = .secondaryLabelColor
    path.lineBreakMode = .byTruncatingMiddle
    let labels = NSStackView(views: [name, path])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 2
    for child in [icon, labels] {
      child.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(child)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
      path.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
    ])
    cell.textField = name
    cell.imageView = icon
    cell.toolTip = url.path
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !updating, urls.indices.contains(table.selectedRow) else { return }
    onSelect?(urls[table.selectedRow])
  }

  private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
    (info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter { ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased()) }
  }

  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
    proposedDropOperation operation: NSTableView.DropOperation
  ) -> NSDragOperation {
    tableView.setDropRow(-1, dropOperation: .on)
    return droppedURLs(info).isEmpty ? [] : .copy
  }

  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    let urls = droppedURLs(info)
    guard !urls.isEmpty else { return false }
    onDrop?(urls)
    return true
  }

  @objc private func removeClickedDocument() {
    guard urls.indices.contains(table.clickedRow) else { return }
    table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
    onRemove?()
  }

  @objc private func addDocuments() { onAdd?() }
  @objc private func removeDocument() { onRemove?() }
}
