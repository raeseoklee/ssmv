import AppKit
import MarkdownCore

@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
  NSMenuItemValidation, NSMenuDelegate
{
  weak var categoryStore: DocumentStore?
  var onCategoriesChanged: (() -> Void)?
  final class CategoryNode {
    let id: UUID?
    var name: String
    var children: [AnyObject] = []
    init(_ id: UUID?, _ name: String) { self.id = id; self.name = name }
  }
  private let unclassified = CategoryNode(nil, "Uncategorized")
  private var groups: [UUID: CategoryNode] = [:]
  private var roots: [AnyObject] = []
  private var collapsed = Set<UUID?>()
  private var collapsingCategory: CategoryNode?
  private var moveMenu = NSMenu()
  private static let draggedDocument = NSPasteboard.PasteboardType("io.github.irae.ssmv.sidebar-document")

  var onSelect: ((URL) -> Void)?
  var onSelectHeading: ((URL, Int) -> Void)?
  var onToggleOutline: (() -> Void)?
  var onAdd: (() -> Void)?
  var onRemove: (() -> Void)?
  var onRemoveAll: (() -> Void)?
  var onSort: ((DocumentSortOrder) -> Void)?
  var documentLoader: ((URL) async throws -> AttributedString?)?
  var onSourceAction: ((URL, String) -> Void)?
  var canSaveSource: ((URL) -> Bool)?
  private var records: [URL: DocumentRecord] = [:]
  private(set) var sortOrder: DocumentSortOrder = .added
  private var addedURLs: [URL] = []

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
  private let removeButton = SidebarActionButton()
  private let outlineButton = SidebarActionButton()
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
    // File opening is handled by the window across the entire sidebar.
    table.unregisterDraggedTypes()
    table.registerForDraggedTypes([Self.draggedDocument])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    let menu = NSMenu()
    menu.delegate = self
    for (title, action) in [("New Category…", #selector(newCategory)), ("New Subcategory…", #selector(newSubcategory)),
      ("Rename Category…", #selector(renameCategory)), ("Delete Category…", #selector(deleteCategory))] {
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    let moveItem = menu.addItem(withTitle: "Move to Category", action: nil, keyEquivalent: "")
    moveItem.submenu = moveMenu
    menu.addItem(.separator())
    let remove = menu.addItem(
      withTitle: "Remove from Sidebar", action: #selector(removeClickedDocument), keyEquivalent: "")
    remove.target = self
    menu.addItem(.separator())
    let removeAll = menu.addItem(
      withTitle: "Remove All from Sidebar…", action: #selector(removeAllDocuments),
      keyEquivalent: "")
    removeAll.target = self
    menu.addItem(.separator())
    for (title, command) in [
      ("Reload", "reload"), ("Copy Source URL", "copy"), ("Open in Browser", "browser"),
      ("Save a Copy…", "save"),
    ] {
      let item = menu.addItem(
        withTitle: title, action: #selector(sourceAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = command
    }
    menu.addItem(.separator())
    let sort = menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Sort By")
    for (title, order) in [
      ("Date Added", DocumentSortOrder.added), ("Name", .name), ("Date Modified", .modified),
    ] {
      let item = submenu.addItem(
        withTitle: title, action: #selector(changeSort(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = order.rawValue
    }
    sort.submenu = submenu
    table.menu = menu
    scroll.documentView = table
    let add = SidebarActionButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add documents")!,
      target: self, action: #selector(addDocuments))
    add.bezelStyle = .regularSquare
    add.toolTip = "Add documents (⌘O)"
    removeButton.image = NSImage(
      systemSymbolName: "minus", accessibilityDescription: "Remove document from sidebar")
    removeButton.target = self
    removeButton.action = #selector(removeDocument)
    removeButton.bezelStyle = .regularSquare
    removeButton.toolTip = "Click to remove the selected document; hold to remove all…"
    let removeAllPress = NSPressGestureRecognizer(
      target: self, action: #selector(removeButtonHeld(_:)))
    removeAllPress.minimumPressDuration = 0.6
    removeAllPress.allowableMovement = 6
    removeButton.addGestureRecognizer(removeAllPress)
    outlineButton.image = NSImage(
      systemSymbolName: "list.bullet.indent", accessibilityDescription: "Document Outline")
    outlineButton.setButtonType(.pushOnPushOff)
    outlineButton.setAccessibilityRole(.checkBox)
    outlineButton.setAccessibilityValue(NSNumber(value: outlineEnabled))
    outlineButton.bezelStyle = .regularSquare
    outlineButton.target = self
    outlineButton.action = #selector(toggleOutline)
    outlineButton.toolTip = "Show or hide document outlines"
    outlineButton.state = outlineEnabled ? .on : .off
    for button in [add, removeButton, outlineButton] {
      button.isBordered = false
      button.contentTintColor = .labelColor
      button.image = button.image?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
      (button.cell as? NSButtonCell)?.showsStateBy = []
      (button.cell as? NSButtonCell)?.highlightsBy = []
      button.widthAnchor.constraint(equalToConstant: 22).isActive = true
      button.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    let actions = NSStackView(views: [add, removeButton, outlineButton])
    actions.spacing = 5
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

  func update(records: [DocumentRecord], selectedID: UUID?) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.sidebarKey, $0) })
    update(
      urls: records.map(\.sidebarKey), selected: records.first { $0.id == selectedID }?.sidebarKey)
  }

  func updateMetadata(_ documents: [DocumentRecord]) {
    records = Dictionary(uniqueKeysWithValues: documents.map { ($0.sidebarKey, $0) })
  }

  func selectDocument(_ key: URL) {
    guard selectedURL != key else { return }
    selectedURL = key
    revealCategory(for: key)
    selectedHeadingID = nil
    refresh()
  }

  private func rebuildGroups() {
    guard let store = categoryStore, !store.categories.isEmpty else {
      groups = [:]; collapsed = []; roots = items; unclassified.children = []
      return
    }
    let categories = store.categories
    var next: [UUID: CategoryNode] = [:]
    for category in categories {
      let node = groups[category.id] ?? CategoryNode(category.id, category.name)
      node.name = category.name; node.children = []; next[category.id] = node
    }
    groups = next
    collapsed = collapsed.filter { id in id.map { groups[$0] != nil } ?? true }
    roots = []; unclassified.children = []
    for category in categories {
      guard let node = groups[category.id] else { continue }
      if let parent = category.parentID.flatMap({ groups[$0] }) { parent.children.append(node) }
      else { roots.append(node) }
    }
    for item in items {
      let group = records[item.url].flatMap { store.categoryID(for: $0.id) }.flatMap { groups[$0] }
      (group ?? unclassified).children.append(item)
    }
    roots.append(unclassified)
  }

  private func revealCategory(for url: URL) {
    guard let store = categoryStore, !groups.isEmpty, let record = records[url] else { return }
    var id = store.categoryID(for: record.id)
    collapsed.remove(id)
    while let current = id {
      id = store.categories.first { $0.id == current }?.parentID
      if let id { collapsed.remove(id) }
    }
  }

  private var clickedCategory: CategoryNode? {
    table.clickedRow >= 0 ? table.item(atRow: table.clickedRow) as? CategoryNode : nil
  }
  private var clickedRecord: DocumentRecord? {
    guard table.clickedRow >= 0, let item = table.item(atRow: table.clickedRow) as? Item else { return nil }
    return records[item.url]
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === table.menu else { return }
    moveMenu.removeAllItems()
    guard let store = categoryStore, let record = clickedRecord else { return }
    let current = store.categoryID(for: record.id)
    func option(_ name: String, id: UUID?, level: Int) {
      let entry = moveMenu.addItem(withTitle: name, action: #selector(moveToCategory(_:)), keyEquivalent: "")
      entry.representedObject = id
      entry.target = self
      entry.indentationLevel = min(15, level)
      entry.state = id == current ? .on : .off
    }
    option(unclassified.name, id: nil, level: 0)
    func append(_ node: CategoryNode, level: Int) {
      option(node.name, id: node.id, level: level)
      for case let child as CategoryNode in node.children { append(child, level: level + 1) }
    }
    for case let node as CategoryNode in roots where node.id != nil { append(node, level: 0) }
  }

  private func modifyCategories(_ operation: (DocumentStore) throws -> Void) {
    guard let store = categoryStore else { return }
    do { try operation(store); onCategoriesChanged?() }
    catch { NSAlert(error: error).runModal() }
  }
  private func namePrompt(_ title: String, initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
    field.stringValue = initial
    field.placeholderString = "Category name"
    field.setAccessibilityLabel("Category name")
    alert.accessoryView = field
    alert.addButton(withTitle: initial.isEmpty ? "Create" : "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }
  @objc private func newCategory() {
    guard let name = namePrompt("New Category") else { return }
    modifyCategories { _ = try $0.createCategory(name: name, parentID: nil) }
  }
  @objc private func newSubcategory() {
    guard let parent = clickedCategory?.id, let name = namePrompt("New Subcategory") else { return }
    modifyCategories { _ = try $0.createCategory(name: name, parentID: parent); collapsed.remove(parent) }
  }
  @objc private func renameCategory() {
    guard let category = clickedCategory, let id = category.id,
      let name = namePrompt("Rename Category", initial: category.name) else { return }
    modifyCategories { try $0.renameCategory(id, name: name) }
  }
  @objc private func deleteCategory() {
    guard let category = clickedCategory, let id = category.id else { return }
    let alert = NSAlert()
    alert.messageText = "Delete “\(category.name)”?"
    alert.informativeText = "Documents stay in your library and their files stay on disk."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Delete Category")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    modifyCategories { try $0.removeCategory(id) }
  }
  @objc private func moveToCategory(_ sender: NSMenuItem) {
    guard let record = clickedRecord else { return }
    modifyCategories { try $0.moveDocument(record.id, to: sender.representedObject as? UUID) }
  }

  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
    guard !groups.isEmpty, let item = item as? Item, item.isFile, let record = records[item.url] else { return nil }
    let writer = NSPasteboardItem()
    writer.setString(record.id.uuidString, forType: Self.draggedDocument)
    return writer
  }
  private func draggedDocumentID(_ info: NSDraggingInfo) -> UUID? {
    guard (info.draggingSource as? NSOutlineView) === table,
      let raw = info.draggingPasteboard.string(forType: Self.draggedDocument),
      let id = UUID(uuidString: raw), categoryStore?.record(id) != nil else { return nil }
    return id
  }
  func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
    proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
    guard let node = item as? CategoryNode, let id = draggedDocumentID(info),
      categoryStore?.categoryID(for: id) != node.id else { return [] }
    table.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
    return .move
  }
  func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
    item: Any?, childIndex index: Int) -> Bool {
    guard let node = item as? CategoryNode, let id = draggedDocumentID(info),
      let store = categoryStore else { return false }
    do { try store.moveDocument(id, to: node.id); onCategoriesChanged?(); return true }
    catch { NSAlert(error: error).runModal(); return false }
  }

  private func sortedKeys(_ urls: [URL]) -> [URL] {
    guard !records.isEmpty else { return sortOrder.sorted(urls) }
    guard sortOrder != .added else { return urls }
    let dates =
      sortOrder == .modified
      ? urls.map { key -> Date? in
        guard let record = records[key] else { return nil }
        if case .localFile(let url) = record.source {
          return try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        }
        return record.sourceModifiedAt
      } : []
    return urls.enumerated().sorted { left, right in
      if sortOrder == .name {
        let result = (records[left.element]?.displayName ?? "").localizedStandardCompare(
          records[right.element]?.displayName ?? "")
        if result != .orderedSame { return result == .orderedAscending }
      } else {
        let a = dates[left.offset] ?? .distantPast
        let b = dates[right.offset] ?? .distantPast
        if a != b { return a > b }
      }
      return left.offset < right.offset
    }.map(\.element)
  }

  func update(urls: [URL], selected: URL?) {
    _ = view
    for url in Array(tasks.keys) where !urls.contains(url) { cancel(url) }
    let old = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
    addedURLs = urls
    items = sortedKeys(urls).map { old[$0] ?? Item(url: $0) }
    rebuildGroups()
    if selectedURL != selected {
      selectedHeadingID = nil
      if let selected { revealCategory(for: selected) }
    }
    selectedURL = selected
    expandedHeadings = expandedHeadings.filter { urls.contains($0.key) }
    refresh()
  }

  func setOutlineEnabled(_ enabled: Bool, document: AttributedString? = nil) {
    _ = view
    outlineEnabled = enabled
    outlineButton.state = enabled ? .on : .off
    outlineButton.setAccessibilityValue(NSNumber(value: enabled))
    outlineButton.needsDisplay = true
    outlineButton.toolTip =
      enabled ? "Document outline on — click to hide" : "Document outline off — click to show"
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
        } else if let documentLoader = self?.documentLoader {
          guard let document = try await documentLoader(url) else {
            guard let self, !Task.isCancelled, self.generations[url] == generation else { return }
            item.children = [Item(url: url, message: "Open to load headings")]
            self.refresh(item: item)
            self.tasks[url] = nil
            self.generations[url] = nil
            return
          }
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
    if changedItem == nil {
      func expand(_ node: CategoryNode) {
        guard !collapsed.contains(node.id) else { table.collapseItem(node); return }
        table.expandItem(node)
        for case let child as CategoryNode in node.children { expand(child) }
      }
      for case let node as CategoryNode in roots { expand(node) }
    }
    if outlineEnabled { for item in expanded where table.row(forItem: item) >= 0 { table.expandItem(item) } }
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
    if let node = item as? CategoryNode { return node.children.count }
    guard let item = item as? Item else { return roots.count }
    if item.isFile { return outlineEnabled ? max(1, item.children.count) : 0 }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let node = item as? CategoryNode { return node.children[index] }
    guard let item = item as? Item else { return roots[index] }
    if item.isFile && item.children.isEmpty {
      item.children = [Item(url: item.url, message: "Loading headings…")]
    }
    return item.children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    if item is CategoryNode { return true }
    guard let item = item as? Item else { return false }
    return item.isFile ? outlineEnabled : !item.children.isEmpty
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    if !updating, let node = notification.userInfo?["NSObject"] as? CategoryNode {
      collapsed.remove(node.id)
      // Let AppKit complete its nested row updates before restoring the selected file.
      Task { @MainActor [weak self] in self?.refresh() }
      return
    }
    guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
    if item.isFile {
      requestOutline(item.url)
    } else if let heading = item.heading {
      expandedHeadings[item.url, default: []].insert(heading.id)
    }
  }

  func outlineViewItemWillCollapse(_ notification: Notification) {
    if !updating, collapsingCategory == nil, let node = notification.userInfo?["NSObject"] as? CategoryNode {
      collapsingCategory = node
      collapsed.insert(node.id)
    }
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    if !updating, let node = notification.userInfo?["NSObject"] as? CategoryNode {
      if collapsingCategory === node { collapsingCategory = nil }
      return
    }
    guard !updating, let item = notification.userInfo?["NSObject"] as? Item,
      let heading = item.heading
    else { return }
    expandedHeadings[item.url]?.remove(heading.id)
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    if item is CategoryNode { return true }
    guard let item = item as? Item else { return false }
    return item.message == nil
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !updating, collapsingCategory == nil else { return }
    if table.selectedRow >= 0, table.item(atRow: table.selectedRow) is CategoryNode {
      removeButton.isEnabled = false
      return
    }
    guard let item = table.item(atRow: table.selectedRow) as? Item, item.message == nil
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
    (item as? Item)?.isFile == true ? 28 : 24
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    if let node = item as? CategoryNode {
      let label = NSTextField(labelWithString: node.name)
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.lineBreakMode = .byTruncatingTail
      let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
      icon.contentTintColor = .secondaryLabelColor
      let row = NSStackView(views: [icon, label])
      row.spacing = 5
      row.toolTip = node.name
      return row
    }
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
    let name = NSTextField(labelWithString: records[url]?.displayName ?? url.lastPathComponent)
    name.lineBreakMode = .byTruncatingMiddle
    name.font = .systemFont(ofSize: 13)
    for child in [icon, name] {
      child.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(child)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 15),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    cell.textField = name
    cell.imageView = icon
    cell.toolTip = records[url]?.sourceLabel ?? url.path
    return cell
  }

  @objc private func removeClickedDocument() {
    guard let item = table.item(atRow: table.clickedRow) as? Item else { return }
    selectedURL = item.url
    onSelect?(item.url)
    onRemove?()
  }
  func setSortOrder(_ order: DocumentSortOrder) {
    guard sortOrder != order else { return }
    sortOrder = order
    update(urls: addedURLs, selected: selectedURL)
  }

  @objc private func changeSort(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let order = DocumentSortOrder(rawValue: raw)
    else { return }
    setSortOrder(order)
    onSort?(order)
  }

  @objc private func sourceAction(_ sender: NSMenuItem) {
    guard let item = table.item(atRow: table.clickedRow) as? Item,
      let command = sender.representedObject as? String
    else { return }
    onSourceAction?(item.url, command)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(sourceAction(_:)) {
      guard let item = table.item(atRow: table.clickedRow) as? Item, let record = records[item.url],
        let command = menuItem.representedObject as? String
      else { return false }
      if command == "copy" || command == "browser" {
        if case .remote = record.source { return true }
        return false
      }
      if command == "save" { return canSaveSource?(item.url) == true }
      return true
    }
    if menuItem.action == #selector(changeSort(_:)) {
      menuItem.state = (menuItem.representedObject as? String) == sortOrder.rawValue ? .on : .off
      return true
    }
    if menuItem.action == #selector(removeAllDocuments) { return !items.isEmpty }
    if menuItem.action == #selector(removeClickedDocument) { return clickedRecord != nil || (table.clickedRow >= 0 && table.item(atRow: table.clickedRow) is Item) }
    if menuItem.action == #selector(newCategory) { return categoryStore != nil }
    if [#selector(newSubcategory), #selector(renameCategory), #selector(deleteCategory)].contains(menuItem.action) {
      return clickedCategory?.id != nil
    }
    return true
  }
  @objc private func removeButtonHeld(_ recognizer: NSPressGestureRecognizer) {
    guard recognizer.state == .began, !items.isEmpty else { return }
    onRemoveAll?()
  }
  @objc private func removeAllDocuments() { onRemoveAll?() }
  @objc private func toggleOutline() { onToggleOutline?() }
  @objc private func addDocuments() { onAdd?() }
  @objc private func removeDocument() { onRemove?() }
}

/// Shared compact treatment; selection stays visible even when the window is not key.
@MainActor
private final class SidebarActionButton: NSButton {
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
    (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
    shape.fill()
    if state == .on {
      NSColor.secondaryLabelColor.setStroke()
      shape.lineWidth = 1
      shape.stroke()
    }
    super.draw(dirtyRect)
  }
}
