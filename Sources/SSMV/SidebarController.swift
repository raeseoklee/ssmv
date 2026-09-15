import AppKit
import MarkdownCore

@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
  NSMenuItemValidation
{
  var onSelect: ((URL) -> Void)?
  var onSelectHeading: ((URL, Int) -> Void)?
  var onToggleOutline: (() -> Void)?
  var onAdd: (() -> Void)?
  var onDrop: (([URL]) -> Void)?
  var onRemove: (() -> Void)?
  var onRemoveAll: (() -> Void)?

  final class Item {
    let url: URL
    let heading: DocumentOutline.Heading?
    let message: String?
    var children: [Item] = []
    var loaded = false
    init(url: URL, heading: DocumentOutline.Heading? = nil, message: String? = nil) {
      self.url = url
      self.heading = heading
      self.message = message
    }
    var isFile: Bool { heading == nil && message == nil }
  }

  private let table = NSOutlineView()
  private let removeButton = NSButton()
  private let outlineButton = NSButton()
  private var items: [Item] = []
  private var tasks: [URL: Task<Void, Never>] = [:]
  private var generations: [URL: UUID] = [:]
  private var updating = false
  private var selectedURL: URL?
  private var selectedHeadingID: Int?
  private var expandedHeadings: [URL: Set<Int>] = [:]
  private(set) var outlineEnabled = true

  override func loadView() {
    view = NSView()
    let title = NSTextField(labelWithString: "Documents")
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .secondaryLabelColor
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let column = NSTableColumn(identifier: .init("Document"))
    table.addTableColumn(column)
    table.outlineTableColumn = column
    table.headerView = nil
    table.style = .sourceList
    table.indentationPerLevel = 12
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Documents sidebar")
    table.registerForDraggedTypes([.fileURL])
    let menu = NSMenu()
    let remove = menu.addItem(
      withTitle: "Remove from Sidebar", action: #selector(removeClickedDocument), keyEquivalent: "")
    remove.target = self
    menu.addItem(.separator())
    let removeAll = menu.addItem(
      withTitle: "Remove All from Sidebar…", action: #selector(removeAllDocuments),
      keyEquivalent: "")
    removeAll.target = self
    table.menu = menu
    scroll.documentView = table
    let add = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add documents")!,
      target: self, action: #selector(addDocuments))
    add.bezelStyle = .inline
    add.toolTip = "Add documents (⌘O)"
    removeButton.image = NSImage(
      systemSymbolName: "minus", accessibilityDescription: "Remove document from sidebar")
    removeButton.target = self
    removeButton.action = #selector(removeDocument)
    removeButton.bezelStyle = .inline
    removeButton.toolTip = "Remove from sidebar; keep file on disk"
    outlineButton.image = NSImage(
      systemSymbolName: "list.bullet.indent", accessibilityDescription: "Document Outline")
    outlineButton.setButtonType(.pushOnPushOff)
    outlineButton.bezelStyle = .inline
    outlineButton.target = self
    outlineButton.action = #selector(toggleOutline)
    outlineButton.toolTip = "Show or hide document outlines"
    outlineButton.state = outlineEnabled ? .on : .off
    let actions = NSStackView(views: [add, removeButton, outlineButton])
    actions.spacing = 8
    for child in [title, scroll, actions] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
      title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
      actions.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      actions.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
    ])
  }

  func update(urls: [URL], selected: URL?) {
    _ = view
    for url in Array(tasks.keys) where !urls.contains(url) { cancel(url) }
    let old = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
    items = urls.map { old[$0] ?? Item(url: $0) }
    if selectedURL != selected { selectedHeadingID = nil }
    selectedURL = selected
    expandedHeadings = expandedHeadings.filter { urls.contains($0.key) }
    refresh()
  }

  func setOutlineEnabled(_ enabled: Bool, document: AttributedString? = nil) {
    _ = view
    outlineEnabled = enabled
    outlineButton.state = enabled ? .on : .off
    if !enabled {
      cancelAll()
      selectedHeadingID = nil
      expandedHeadings = [:]
      for item in items {
        item.children = []
        item.loaded = false
      }
    }
    refresh()
    if enabled, let selectedURL, let item = items.first(where: { $0.url == selectedURL }) {
      if let document { provideDocument(document, for: selectedURL) }
      table.expandItem(item)
    }
  }

  func invalidateOutline(_ url: URL) {
    cancel(url)
    guard let item = items.first(where: { $0.url == url }) else { return }
    item.loaded = false
    item.children = []
    refresh(item: item)
  }

  func finishPendingDocument(_ url: URL, failed: Bool) {
    guard let item = items.first(where: { $0.url == url }), !item.loaded,
      tasks[url] == nil
    else { return }
    item.children = [
      Item(url: url, message: failed ? "Couldn’t read headings" : "Expand to load headings")
    ]
    refresh(item: item)
  }

  func provideDocument(_ document: AttributedString, for url: URL) {
    guard outlineEnabled else { return }
    requestOutline(url, document: document)
  }

  func cancelAll() { for url in Array(tasks.keys) { cancel(url) } }

  private func cancel(_ url: URL) {
    tasks.removeValue(forKey: url)?.cancel()
    generations.removeValue(forKey: url)
  }

  private func requestOutline(_ url: URL, document: AttributedString? = nil) {
    guard outlineEnabled, let item = items.first(where: { $0.url == url }) else { return }
    if document == nil && (item.loaded || tasks[url] != nil) { return }
    cancel(url)
    let generation = UUID()
    generations[url] = generation
    tasks[url] = Task { [weak self] in
      do {
        let parsed: AttributedString
        if let document {
          parsed = document
        } else {
          parsed = try await DocumentLoader.shared.load(url)
        }
        let build = Task.detached { try DocumentOutline.build(parsed) }
        let outline = try await withTaskCancellationHandler {
          try await build.value
        } onCancel: {
          build.cancel()
        }
        guard let self, !Task.isCancelled, self.generations[url] == generation else { return }
        self.install(outline, into: item)
      } catch {
        guard let self, !Task.isCancelled, self.generations[url] == generation else { return }
        item.children = [Item(url: url, message: "Couldn’t read headings")]
        item.loaded = true
        self.refresh(item: item)
      }
      guard let self, self.generations[url] == generation else { return }
      self.tasks[url] = nil
      self.generations[url] = nil
    }
  }

  private func install(_ outline: DocumentOutline, into item: Item) {
    var nodes: [Int: Item] = [:]
    item.children = []
    for heading in outline.headings {
      let node = Item(url: item.url, heading: heading)
      nodes[heading.id] = node
      if let parent = heading.parentID.flatMap({ nodes[$0] }) {
        parent.children.append(node)
      } else {
        item.children.append(node)
      }
    }
    if outline.isTruncated {
      item.children.append(Item(url: item.url, message: "First 2,000 headings shown"))
    }
    if item.children.isEmpty { item.children = [Item(url: item.url, message: "No headings")] }
    item.loaded = true
    refresh(item: item)
  }

  private func refresh(item changedItem: Item? = nil) {
    let clip = table.enclosingScrollView?.contentView
    let origin = clip?.bounds.origin ?? .zero
    let topRow = table.row(at: NSPoint(x: 0, y: origin.y))
    let anchor = topRow >= 0 ? table.item(atRow: topRow) as? Item : nil
    let anchorOffset = topRow >= 0 ? origin.y - table.rect(ofRow: topRow).minY : 0
    updating = true
    let expanded = items.filter { table.isItemExpanded($0) }
    if let changedItem {
      table.reloadItem(changedItem, reloadChildren: true)
    } else {
      table.reloadData()
    }
    if outlineEnabled { for item in expanded { table.expandItem(item) } }
    func restore(_ item: Item) {
      if let heading = item.heading, expandedHeadings[item.url]?.contains(heading.id) == true {
        table.expandItem(item)
      }
      for child in item.children { restore(child) }
    }
    if outlineEnabled { for item in expanded { restore(item) } }
    func selectedItem(_ item: Item) -> Item? {
      if item.url == selectedURL && item.heading?.id == selectedHeadingID { return item }
      for child in item.children { if let found = selectedItem(child) { return found } }
      return nil
    }
    let selection =
      items.compactMap { selectedItem($0) }.first
      ?? items.first { $0.url == selectedURL }
    let visibleSelection =
      selection.flatMap { table.row(forItem: $0) >= 0 ? $0 : nil }
      ?? items.first { $0.url == selectedURL }
    if let visibleSelection, table.row(forItem: visibleSelection) >= 0 {
      table.selectRowIndexes(
        IndexSet(integer: table.row(forItem: visibleSelection)), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    removeButton.isEnabled = selectedURL != nil
    table.layoutSubtreeIfNeeded()
    if let clip, let anchor {
      let row = table.row(forItem: anchor)
      if row >= 0 {
        clip.scroll(to: NSPoint(x: origin.x, y: table.rect(ofRow: row).minY + anchorOffset))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
      }
    }
    updating = false
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = item as? Item else { return items.count }
    if item.isFile { return outlineEnabled ? max(1, item.children.count) : 0 }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let item = item as? Item else { return items[index] }
    if item.isFile && item.children.isEmpty {
      item.children = [Item(url: item.url, message: "Loading headings…")]
    }
    return item.children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    guard let item = item as? Item else { return false }
    return item.isFile ? outlineEnabled : !item.children.isEmpty
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
    if item.isFile {
      requestOutline(item.url)
    } else if let heading = item.heading {
      expandedHeadings[item.url, default: []].insert(heading.id)
    }
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard !updating, let item = notification.userInfo?["NSObject"] as? Item,
      let heading = item.heading
    else { return }
    expandedHeadings[item.url]?.remove(heading.id)
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    (item as? Item)?.message == nil
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !updating, let item = table.item(atRow: table.selectedRow) as? Item, item.message == nil
    else { return }
    selectedURL = item.url
    selectedHeadingID = item.heading?.id
    removeButton.isEnabled = true
    if let heading = item.heading {
      onSelectHeading?(item.url, heading.id)
    } else {
      onSelect?(item.url)
    }
  }

  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    (item as? Item)?.isFile == true ? 46 : 26
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let item = item as? Item else { return nil }
    if item.isFile { return documentCell(item.url) }
    let cell = NSTableCellView()
    let text = NSTextField(labelWithString: item.heading?.title ?? item.message ?? "")
    text.font = .systemFont(ofSize: 12)
    text.textColor = item.message == nil ? .labelColor : .secondaryLabelColor
    text.lineBreakMode = .byTruncatingTail
    text.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    cell.textField = text
    cell.toolTip = text.stringValue
    return cell
  }

  private func documentCell(_ url: URL) -> NSView {
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
      icon.centerYAnchor.constraint(equalTo: name.centerYAnchor),
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

  private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
    (info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter { ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased()) }
  }
  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
    return droppedURLs(info).isEmpty ? [] : .copy
  }
  func outlineView(
    _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
  ) -> Bool {
    let urls = droppedURLs(info)
    guard !urls.isEmpty else { return false }
    onDrop?(urls)
    return true
  }
  @objc private func removeClickedDocument() {
    guard let item = table.item(atRow: table.clickedRow) as? Item else { return }
    selectedURL = item.url
    onSelect?(item.url)
    onRemove?()
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(removeAllDocuments) { return !items.isEmpty }
    if menuItem.action == #selector(removeClickedDocument) { return table.clickedRow >= 0 }
    return true
  }
  @objc private func removeAllDocuments() { onRemoveAll?() }
  @objc private func toggleOutline() { onToggleOutline?() }
  @objc private func addDocuments() { onAdd?() }
  @objc private func removeDocument() { onRemove?() }
}
