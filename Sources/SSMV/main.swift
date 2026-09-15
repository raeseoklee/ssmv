import AppKit
import CoreServices
import MarkdownCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var windows: [ViewerWindow] = []
  private lazy var updateChecker = HomebrewUpdateChecker(
    currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? "")
  private var pendingUpdateVersion: String?
  static let homebrewUpdateCommands = "brew update\nbrew upgrade --cask raeseoklee/tap/ssmv"

  static func updateAlert(version: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "SSMV \(version) is available"
    alert.informativeText =
      "Update through Homebrew to use the supported installation process. Quit SSMV, then run these commands in Terminal:\n\n"
      + homebrewUpdateCommands
    alert.addButton(withTitle: "Copy Commands")
    alert.addButton(withTitle: "Dismiss")
    return alert
  }

  @objc private func presentPendingUpdate(_ notification: Notification? = nil) {
    guard NSApp.isActive, let version = pendingUpdateVersion,
      let viewer = windows.first(where: { !$0.isClosing && $0.window?.isKeyWindow == true })
        ?? windows.first(where: { !$0.isClosing && $0.window?.isVisible == true }),
      let window = viewer.window, window.attachedSheet == nil
    else { return }
    pendingUpdateVersion = nil
    let alert = Self.updateAlert(version: version)
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewUpdateCommands, forType: .string)
      }
    }
    updateChecker.markNotified(version)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    presentPendingUpdate()
  }

  override init() {
    super.init()
    PreferencesMigration.migrate(
      defaults: .standard,
      legacyDomain: UserDefaults.standard.persistentDomain(forName: "io.github.irae.mdview") ?? [:])
  }

  var outlineEnabled: Bool {
    UserDefaults.standard.object(forKey: "showDocumentOutline") as? Bool ?? true
  }

  @objc func toggleDocumentOutline(_ sender: Any?) {
    let enabled = !outlineEnabled
    UserDefaults.standard.set(enabled, forKey: "showDocumentOutline")
    for viewer in windows { viewer.setOutlineEnabled(enabled) }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleDocumentOutline(_:)) {
      menuItem.state = outlineEnabled ? .on : .off
    }
    return true
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
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let credits = NSMutableAttributedString(
      string:
        "So Simple Markdown Viewer\n\nA lightweight Markdown viewer for macOS.\nOpen documents. Navigate headings.\nExport to PDF.\n\nGitHub · MIT License",
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
      ])
    for (label, address) in [
      ("GitHub", "https://github.com/raeseoklee/ssmv"),
      ("MIT License", "https://github.com/raeseoklee/ssmv/blob/main/LICENSE"),
    ] {
      credits.addAttribute(
        .link, value: URL(string: address)!,
        range: (credits.string as NSString).range(of: label))
    }
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "SSMV",
      .credits: credits,
    ])
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Install hooks may be sandboxed; register our document claims on normal launch.
    _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    NSApp.setActivationPolicy(.regular)
    buildMenu()
    if windows.isEmpty { showWelcome() }
    NSApp.activate(ignoringOtherApps: true)
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(presentPendingUpdate(_:)), name: name, object: nil)
    }
    Task { [weak self] in
      guard let self else { return }
      self.pendingUpdateVersion = await self.updateChecker.check()
      self.presentPendingUpdate()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let exporting = windows.filter { $0.hasPDFExport }
    guard !exporting.isEmpty else { return .terminateNow }
    for viewer in exporting { viewer.cancelPDFExport() }
    Task {
      while exporting.contains(where: { $0.hasPDFExport }) {
        try? await Task.sleep(for: .milliseconds(50))
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
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
    let available = windows.filter { !$0.isClosing }
    let viewer =
      available.first(where: { $0.window?.isKeyWindow == true }) ?? available.first
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
    add(file, "Remove All from Sidebar…", #selector(ViewerWindow.confirmRemoveAllDocuments))
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
    add(view, "Show Document Outline", #selector(toggleDocumentOutline(_:)), target: self)
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
  private var source: String?
  private var pendingHeading: (url: URL, id: Int)?
  var exportJob: PDFExportJob?
  private(set) var isClosing = false
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var renderGeneration = 0
  private var isRendering = false
  private var displayedURL: URL?
  private var scrollRestoration = ScrollRestoration()
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
    // Lay out the visible region on demand instead of blocking on the whole document.
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.layoutManager?.backgroundLayoutEnabled = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 36, height: 28)
    textView.backgroundColor = .textBackgroundColor
    textView.delegate = self
    textView.setAccessibilityLabel("Markdown document")
    scroll.documentView = textView
    NotificationCenter.default.addObserver(
      self, selector: #selector(userStartedScrolling(_:)),
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
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
    sidebar.onSelect = { [weak self] url in
      self?.pendingHeading = nil
      self?.selectDocument(url)
    }
    sidebar.onSelectHeading = { [weak self] url, id in self?.navigateToHeading(url, id: id) }
    sidebar.onToggleOutline = { [weak owner] in owner?.toggleDocumentOutline(nil) }
    sidebar.setOutlineEnabled(owner.outlineEnabled)
    sidebar.onAdd = { [weak owner] in owner?.openDocument(nil) }
    sidebar.onDrop = { [weak self] urls in self?.addDocuments(urls) }
    sidebar.onRemove = { [weak self] in self?.removeSelectedDocument() }
    sidebar.onRemoveAll = { [weak self] in self?.confirmRemoveAllDocuments() }
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
    if let fileURL, displayedURL == fileURL, shelf.urls.contains(fileURL) {
      scrollPositions[fileURL] = scrollRestoration.positionToSave(
        current: textView.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    if let previous = fileURL, previous != url {
      sidebar.finishPendingDocument(previous, failed: false)
    }
    parsed = nil
    source = nil
    if pendingHeading?.url != url { pendingHeading = nil }
    sidebar.invalidateOutline(url)
    fileURL = url
    window?.title = url.lastPathComponent
    window?.representedURL = url
    generation += 1
    let request = generation
    loadTask?.cancel()
    renderTask?.cancel()
    renderGeneration += 1
    isRendering = false
    displayedURL = nil
    scrollRestoration.clear()
    showMessage("Opening document…", detail: url.lastPathComponent)
    loadTask = Task { [weak self] in
      do {
        let snapshot = try await DocumentLoader.shared.loadSnapshot(url)
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.parsed = snapshot.document
        self.source = snapshot.source
        self.sidebar.provideDocument(snapshot.document, for: url)
        self.render(restoring: self.scrollPositions[url] ?? .zero)
      } catch {
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.parsed = nil
        self.pendingHeading = nil
        self.sidebar.finishPendingDocument(url, failed: true)
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

  static func removeAllConfirmation(count: Int) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Remove all documents from the sidebar?"
    alert.informativeText =
      "This will clear all \(count) entries from the list. The original files will remain on disk."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Remove All")
    alert.buttons[0].keyEquivalent = "\r"
    alert.buttons[1].hasDestructiveAction = true
    return alert
  }

  @objc func confirmRemoveAllDocuments() {
    guard !shelf.urls.isEmpty, let window, window.attachedSheet == nil else { return }
    Self.removeAllConfirmation(count: shelf.urls.count).beginSheetModal(for: window) {
      [weak self] response in
      guard response == .alertSecondButtonReturn, let self, !self.isClosing else { return }
      self.shelf = DocumentShelf()
      self.scrollPositions.removeAll()
      self.removeSelectedDocument()
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
      renderTask?.cancel()
      renderGeneration += 1
      isRendering = false
      displayedURL = nil
      scrollRestoration.clear()
      parsed = nil
      source = nil
      pendingHeading = nil
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

  private func render(restoring position: NSPoint? = nil) {
    guard let parsed, let fileURL else { return }
    scrollRestoration.begin(
      at: position, current: textView.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    renderTask?.cancel()
    renderGeneration += 1
    let request = renderGeneration
    let size = fontSize
    isRendering = true
    renderTask = Task { [weak self] in
      var started = false
      do {
        try await MarkdownRenderer.renderIncrementally(parsed, size: size) { [weak self] chunk in
          guard let self, self.renderGeneration == request else { return }
          autoreleasepool {
            if !started {
              self.textView.textStorage?.setAttributedString(chunk)
              self.textView.scroll(.zero)
              self.displayedURL = fileURL
              started = true
            } else {
              self.textView.textStorage?.beginEditing()
              self.textView.textStorage?.append(chunk)
              self.textView.textStorage?.endEditing()
            }
          }
        }
        guard let self, !Task.isCancelled, self.renderGeneration == request else { return }
        if !started {
          self.textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
          self.displayedURL = fileURL
        }
        self.isRendering = false
        // Do not override scrolling performed while chunks were appearing.
        if let target = self.scrollRestoration.target,
          self.textView.enclosingScrollView?.contentView.bounds.origin == .zero
        {
          self.textView.scroll(target)
        }
        self.scrollRestoration.clear()
        self.revealPendingHeading()
      } catch is CancellationError {
        // A newer render or document owns the view now.
      } catch {
        guard let self, self.renderGeneration == request else { return }
        self.isRendering = false
        self.showMessage("Couldn’t display document", detail: error.localizedDescription)
      }
    }
  }

  func setOutlineEnabled(_ enabled: Bool) {
    sidebar.setOutlineEnabled(enabled, document: parsed)
    if !enabled { pendingHeading = nil }
  }

  private func navigateToHeading(_ url: URL, id: Int) {
    pendingHeading = (url, id)
    if url != fileURL { selectDocument(url) } else { revealPendingHeading() }
  }

  private func revealPendingHeading() {
    guard !isRendering, let pendingHeading, pendingHeading.url == displayedURL,
      let storage = textView.textStorage
    else { return }
    var target: NSRange?
    storage.enumerateAttribute(.documentHeadingID, in: NSRange(location: 0, length: storage.length))
    { value, range, stop in
      if value as? Int == pendingHeading.id {
        target = range
        stop.pointee = true
      }
    }
    self.pendingHeading = nil
    guard let target else { return }
    scrollRestoration.clear()
    textView.scrollRangeToVisible(target)
    textView.showFindIndicator(for: target)
  }

  @objc private func userStartedScrolling(_ notification: Notification) {
    scrollRestoration.clear()
  }

  @objc func exportPDF(_ sender: Any?) {
    guard exportJob == nil, !isRendering, let source, let fileURL, let window else { return }
    let panel = NSSavePanel()
    panel.title = "Export as PDF"
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".pdf"
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }
      guard self.exportJob == nil else { return }
      let job = PDFExportJob()
      self.exportJob = job
      job.start(source: source, fileURL: fileURL, destination: destination, owner: window) {
        [weak self] error in
        self?.finishPDFExport(error)
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(confirmRemoveAllDocuments) {
      return !shelf.urls.isEmpty && window?.attachedSheet == nil
    }
    if menuItem.action == #selector(exportPDF(_:)) {
      return source != nil && fileURL != nil && !isRendering && exportJob == nil
    }
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

  func window(
    _ window: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    // Let AppKit reveal the title and toolbar with the menu bar at the top edge.
    var options = proposedOptions.subtracting(.hideMenuBar)
    options.formUnion([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    if !options.contains(.hideDock) { options.insert(.autoHideDock) }
    return options
  }

  func finishPDFExport(_ error: Error?) {
    exportJob = nil
    if isClosing { appDelegate?.windows.removeAll { $0 === self } }
    if let error, let window, window.isVisible {
      NSAlert(error: error).beginSheetModal(for: window)
    }
  }

  var hasPDFExport: Bool { exportJob != nil }

  func cancelPDFExport() { exportJob?.cancelExport() }

  func windowWillClose(_ notification: Notification) {
    sidebar.cancelAll()
    isClosing = true
    exportJob?.cancelExport()
    loadTask?.cancel()
    renderTask?.cancel()
    if !hasPDFExport { appDelegate?.windows.removeAll { $0 === self } }
  }
}

if CommandLine.arguments.dropFirst().first == "--register-documents" {
  let result = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
  if result != noErr {
    FileHandle.standardError.write(Data("Document registration failed: \(result)\n".utf8))
  }
  exit(result == noErr ? 0 : 1)
}

let app = NSApplication.shared
if CommandLine.arguments.dropFirst().first == "--export-pdf" {
  app.setActivationPolicy(.prohibited)
  exit(runPDFExportHelper(CommandLine.arguments))
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
