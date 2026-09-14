import AppKit
import MarkdownCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var windows: [ViewerWindow] = []

  override init() {
    super.init()
    PreferencesMigration.migrate(
      defaults: .standard,
      legacyDomain: UserDefaults.standard.persistentDomain(forName: "io.github.irae.mdview") ?? [:])
  }

  @objc func showShortcutHelp(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "SSMV Keyboard Shortcuts"
    alert.informativeText =
      "⌘ Command · ⇧ Shift · ⌃ Control · ⌥ Option\n🌐 Fn (Function / 기능 키)\n\nOpen: ⌘O\nFind: ⌘F\nExport PDF: ⇧⌘E\nToggle sidebar: ⌃⌘S\nFull screen: ⌃⌘F\n\nThe globe symbol in a macOS shortcut means the Fn key. For example, ⌃🌐C means Control + Fn + C."
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
  }

  @objc func showAbout(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "SSMV",
      .credits: NSAttributedString(string: "So Simple Markdown Viewer"),
    ])
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    buildMenu()
    if windows.isEmpty { showWelcome() }
    NSApp.activate(ignoringOtherApps: true)
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    open(filenames.map { URL(fileURLWithPath: $0) })
    sender.reply(toOpenOrPrint: .success)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showWelcome() }
    return true
  }

  func showWelcome() {
    let viewer = ViewerWindow(owner: self)
    windows.append(viewer)
    viewer.showWindow(nil)
  }

  func open(_ url: URL) { open([url]) }

  func open(_ urls: [URL]) {
    let viewer =
      windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first
      ?? ViewerWindow(owner: self)
    if !windows.contains(where: { $0 === viewer }) { windows.append(viewer) }
    viewer.addDocuments(urls)
    viewer.showWindow(nil)
    for url in urls { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
  }

  @objc func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "md") ?? .plainText,
      UTType(filenameExtension: "markdown") ?? .plainText, .plainText,
    ]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK { open(panel.urls) }
  }

  @objc func setTheme(_ sender: NSMenuItem) {
    UserDefaults.standard.set(sender.tag, forKey: "appearance")
    applyTheme()
  }

  func applyTheme() {
    let selected = UserDefaults.standard.integer(forKey: "appearance")
    NSApp.appearance =
      selected == 1
      ? NSAppearance(named: .aqua) : selected == 2 ? NSAppearance(named: .darkAqua) : nil
    if let submenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu {
      for item in submenu.items
      where (0...2).contains(item.tag) && item.action == #selector(setTheme(_:)) {
        item.state = item.tag == selected ? .on : .off
      }
    }
  }

  func buildMenu() {
    let main = NSMenu()
    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let submenu = NSMenu(title: title)
      item.submenu = submenu
      main.addItem(item)
      return submenu
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
      target: AnyObject? = nil
    ) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
      item.target = target
      item.keyEquivalentModifierMask = .command
    }
    let app = menu("SSMV")
    add(app, "About SSMV", #selector(showAbout(_:)), target: self)
    app.addItem(.separator())
    add(app, "Hide SSMV", #selector(NSApplication.hide(_:)), "h")
    app.addItem(.separator())
    add(app, "Quit SSMV", #selector(NSApplication.terminate(_:)), "q")
    let file = menu("File")
    add(file, "Open…", #selector(openDocument(_:)), "o", target: self)
    add(file, "Reload", #selector(ViewerWindow.reload(_:)), "r")
    add(file, "Remove from Sidebar", #selector(ViewerWindow.removeSelectedDocument), "\u{8}")
    file.addItem(.separator())
    let export = file.addItem(
      withTitle: "Export as PDF…", action: #selector(ViewerWindow.exportPDF(_:)), keyEquivalent: "e"
    )
    export.keyEquivalentModifierMask = [.command, .shift]
    file.addItem(.separator())
    add(file, "Reveal in Finder", #selector(ViewerWindow.reveal(_:)))
    add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
    let edit = menu("Edit")
    add(edit, "Copy", #selector(NSText.copy(_:)), "c")
    add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
    let find = edit.addItem(
      withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)),
      keyEquivalent: "f")
    find.tag = NSTextFinder.Action.showFindInterface.rawValue
    edit.addItem(.separator())
    let characters = edit.addItem(
      withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
      keyEquivalent: " ")
    characters.keyEquivalentModifierMask = [.command, .control]
    let view = menu("View")
    let toggle = view.addItem(
      withTitle: "Toggle Sidebar", action: #selector(ViewerWindow.toggleSidebar(_:)),
      keyEquivalent: "s")
    toggle.keyEquivalentModifierMask = [.command, .control]
    view.addItem(.separator())
    for (tag, title) in ["System Appearance", "Light", "Dark"].enumerated() {
      let item = view.addItem(withTitle: title, action: #selector(setTheme(_:)), keyEquivalent: "")
      item.target = self
      item.tag = tag
    }
    view.addItem(.separator())
    add(view, "Increase Text Size", #selector(ViewerWindow.increaseSize(_:)), "+")
    add(view, "Decrease Text Size", #selector(ViewerWindow.decreaseSize(_:)), "-")
    add(view, "Actual Text Size", #selector(ViewerWindow.resetSize(_:)), "0")
    view.addItem(.separator())
    let fullscreen = view.addItem(
      withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f")
    fullscreen.keyEquivalentModifierMask = [.command, .control]
    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    let help = menu("Help")
    add(help, "Keyboard Shortcuts…", #selector(showShortcutHelp(_:)), target: self)
    NSApp.helpMenu = help
    NSApp.windowsMenu = window
    NSApp.mainMenu = main
    applyTheme()
  }
}

@MainActor
final class ViewerWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
  NSToolbarDelegate, NSMenuItemValidation
{
  weak var appDelegate: AppDelegate?
  var fileURL: URL?
  private let textView = NSTextView()
  private let split = NSSplitViewController()
  private let sidebar = SidebarController()
  private var shelf = DocumentShelf()
  private var scrollPositions: [URL: NSPoint] = [:]
  private var parsed: AttributedString?
  private var loadTask: Task<Void, Never>?
  private var generation = 0
  private var fontSize: CGFloat = 16

  init(owner: AppDelegate) {
    self.appDelegate = owner
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 840, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = "SSMV"
    window.minSize = NSSize(width: 620, height: 320)
    window.tabbingMode = .disallowed
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("ReaderWindow")
    window.center()
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    textView.frame = scroll.bounds
    textView.autoresizingMask = [.width]
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 36, height: 28)
    textView.backgroundColor = .textBackgroundColor
    textView.delegate = self
    textView.setAccessibilityLabel("Markdown document")
    scroll.documentView = textView
    let reader = NSViewController()
    reader.view = scroll
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 320
    sidebarItem.canCollapse = true
    split.addSplitViewItem(sidebarItem)
    let readerItem = NSSplitViewItem(viewController: reader)
    readerItem.minimumThickness = 400
    split.addSplitViewItem(readerItem)
    window.contentViewController = split
    split.splitView.setPosition(230, ofDividerAt: 0)
    sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
    sidebar.onSelect = { [weak self] url in self?.selectDocument(url) }
    sidebar.onAdd = { [weak owner] in owner?.openDocument(nil) }
    sidebar.onDrop = { [weak self] urls in self?.addDocuments(urls) }
    sidebar.onRemove = { [weak self] in self?.removeSelectedDocument() }
    let toolbar = NSToolbar(identifier: "ReaderToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    if let saved = UserDefaults.standard.data(forKey: "documentShelf"),
      let restored = try? JSONDecoder().decode(DocumentShelf.self, from: saved)
    {
      shelf = restored
    }
    sidebar.update(urls: shelf.urls, selected: shelf.selectedURL)
    window.makeFirstResponder(textView)
    showMessage(
      "SSMV",
      detail:
        "So Simple Markdown Viewer.\n\nChoose File → Open… or press ⌘O.\nYou can also open documents from Finder with SSMV."
    )
    if let selected = shelf.selectedURL { load(selected) }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func showMessage(_ title: String, detail: String) {
    let output = NSMutableAttributedString(
      string: title + "\n\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.labelColor,
      ])
    output.append(
      NSAttributedString(
        string: detail,
        attributes: [
          .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    textView.textStorage?.setAttributedString(output)
  }

  func load(_ url: URL) {
    if let fileURL, shelf.urls.contains(fileURL) {
      scrollPositions[fileURL] = textView.enclosingScrollView?.contentView.bounds.origin
    }
    parsed = nil
    fileURL = url
    window?.title = url.lastPathComponent
    window?.representedURL = url
    generation += 1
    let request = generation
    loadTask?.cancel()
    showMessage("Opening document…", detail: url.lastPathComponent)
    loadTask = Task { [weak self] in
      do {
        let document = try await DocumentLoader.shared.load(url)
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.parsed = document
        self.render()
        self.textView.layoutManager?.ensureLayout(for: self.textView.textContainer!)
        self.textView.scroll(self.scrollPositions[url] ?? .zero)
      } catch {
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.parsed = nil
        self.showMessage("Couldn’t open document", detail: error.localizedDescription)
      }
    }
  }

  func addDocuments(_ urls: [URL]) {
    shelf.add(urls)
    saveShelf()
    sidebar.update(urls: shelf.urls, selected: shelf.selectedURL)
    if let selected = shelf.selectedURL, selected != fileURL { load(selected) }
  }

  private func selectDocument(_ url: URL) {
    guard url != fileURL else { return }
    shelf.select(url)
    saveShelf()
    load(url)
  }

  private func saveShelf() {
    if let data = try? JSONEncoder().encode(shelf) {
      UserDefaults.standard.set(data, forKey: "documentShelf")
    }
  }

  @objc func removeSelectedDocument() {
    if let selected = shelf.selectedURL { scrollPositions.removeValue(forKey: selected) }
    shelf.removeSelected()
    saveShelf()
    sidebar.update(urls: shelf.urls, selected: shelf.selectedURL)
    if let selected = shelf.selectedURL {
      load(selected)
    } else {
      generation += 1
      loadTask?.cancel()
      parsed = nil
      fileURL = nil
      window?.title = "SSMV"
      window?.representedURL = nil
      showMessage(
        "No documents",
        detail: "Add documents with + or ⌘O, or drag Markdown files into the sidebar.")
    }
  }

  @objc func toggleSidebar(_ sender: Any?) {
    let item = split.splitViewItems[0]
    item.isCollapsed.toggle()
    UserDefaults.standard.set(item.isCollapsed, forKey: "sidebarCollapsed")
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.init("sidebar"), .init("addDocument"), .flexibleSpace]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.init("sidebar"), .init("addDocument"), .flexibleSpace]
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    if identifier.rawValue == "sidebar" {
      item.label = "Toggle Sidebar"
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
      item.target = self
      item.action = #selector(toggleSidebar(_:))
    } else if identifier.rawValue == "addDocument" {
      item.label = "Add Documents"
      item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: item.label)
      item.target = appDelegate
      item.action = #selector(AppDelegate.openDocument(_:))
    } else {
      return nil
    }
    item.toolTip = item.label
    return item
  }

  private func render() {
    guard let parsed else { return }
    textView.textStorage?.setAttributedString(MarkdownRenderer.render(parsed, size: fontSize))
  }

  @objc func exportPDF(_ sender: Any?) {
    guard let document = parsed, let fileURL, let window else { return }
    let panel = NSSavePanel()
    panel.title = "Export as PDF"
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".pdf"
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }
      do {
        try PDFExporter.export(document, title: fileURL.lastPathComponent, to: destination)
      } catch {
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(exportPDF(_:)) { return parsed != nil && fileURL != nil }
    return true
  }

  @objc func reload(_ sender: Any?) { if let fileURL { load(fileURL) } }
  @objc func reveal(_ sender: Any?) {
    if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
  }
  @objc func increaseSize(_ sender: Any?) {
    fontSize = min(32, fontSize + 2)
    render()
  }
  @objc func decreaseSize(_ sender: Any?) {
    fontSize = max(10, fontSize - 2)
    render()
  }
  @objc func resetSize(_ sender: Any?) {
    fontSize = 16
    render()
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else {
      return true
    }
    if url.isFileURL && ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
      appDelegate?.open(url)
    } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    loadTask?.cancel()
    appDelegate?.windows.removeAll { $0 === self }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
