import AppKit
import CoreServices
import MarkdownCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var windows: [ViewerWindow] = []
  var documentStore: DocumentStore?
  var inputLoader: DocumentInputLoader?
  var processedRequests = Set<URL>()
  var isRecoveringRequests = false
  private var documentStoreError: Error?

  init(store: DocumentStore) {
    super.init()
    documentStore = store
    inputLoader = DocumentInputLoader(store: store)
  }
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
    do {
      let store = try DocumentStore()
      documentStore = store
      inputLoader = DocumentInputLoader(store: store)
    } catch { documentStoreError = error }

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
      "⌘ Command · ⇧ Shift · ⌃ Control · ⌥ Option\n🌐 Fn (Function / 기능 키)\n\nOpen: ⌘O\nOpen URL: ⇧⌘O\nReload: ⌘R\nFind: ⌘F\nExport PDF: ⇧⌘E\nToggle sidebar: ⌃⌘S\nFull screen: ⌃⌘F\n\nThe globe symbol in a macOS shortcut means the Fn key. For example, ⌃🌐C means Control + Fn + C."
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
    if let documentStoreError {
      presentInputError(documentStoreError)
    } else {
      retryPendingImports(nil)
    }
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

  func application(_ application: NSApplication, open urls: [URL]) {
    let local = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "ssmvrequest" }
    if !local.isEmpty { open(local) }
    for url in urls where url.pathExtension.lowercased() == "ssmvrequest" { consumeRequest(url) }
    for url in urls where !url.isFileURL && url.pathExtension.lowercased() != "ssmvrequest" {
      openRemote(url)
    }
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
    let openURL = file.addItem(
      withTitle: "Open URL…", action: #selector(openURLDocument(_:)), keyEquivalent: "o")
    openURL.target = self
    openURL.keyEquivalentModifierMask = [.command, .shift]
    add(file, "Open Clipboard as Markdown", #selector(openClipboardDocument(_:)), target: self)
    add(file, "Save a Copy…", #selector(ViewerWindow.saveMarkdownCopy(_:)))
    add(file, "Manage Imported Documents…", #selector(manageImports(_:)), target: self)
    add(file, "Retry Pending Imports", #selector(retryPendingImports(_:)), target: self)
    add(file, "Cancel Loading", #selector(ViewerWindow.cancelLoading(_:)))
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
  private var documentID: UUID?
  private var store: DocumentStore? { appDelegate?.documentStore }
  private var currentRecord: DocumentRecord? { documentID.flatMap { store?.record($0) } }
  private var snapshotBaseURL: URL?
  private var isLoading = false
  private let statusLabel = NSTextField(labelWithString: "")
  private let textView = NSTextView()
  private let split = NSSplitViewController()
  private let sidebar = SidebarController()
  private var scrollPositions: [UUID: NSPoint] = [:]
  private var parsed: AttributedString?
  private var source: String?
  private var pendingHeading: (documentID: UUID, id: Int)?
  var exportJob: PDFExportJob?
  private(set) var isClosing = false
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var renderGeneration = 0
  private var isRendering = false
  private var displayedID: UUID?
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
    let readerView = NSView()
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle
    for child in [scroll, statusLabel] {
      child.translatesAutoresizingMaskIntoConstraints = false
      readerView.addSubview(child)
    }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: readerView.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: readerView.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: readerView.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
      statusLabel.leadingAnchor.constraint(equalTo: readerView.leadingAnchor, constant: 12),
      statusLabel.trailingAnchor.constraint(equalTo: readerView.trailingAnchor, constant: -12),
      statusLabel.bottomAnchor.constraint(equalTo: readerView.bottomAnchor, constant: -6),
      statusLabel.heightAnchor.constraint(equalToConstant: 16),
    ])
    reader.view = readerView
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
    sidebar.onSelect = { [weak self] key in
      guard let id = key.host.flatMap(UUID.init(uuidString:)) else { return }
      self?.pendingHeading = nil
      self?.selectDocument(id)
    }
    sidebar.onSelectHeading = { [weak self] key, headingID in
      guard let id = key.host.flatMap(UUID.init(uuidString:)) else { return }
      self?.navigateToHeading(id, id: headingID)
    }
    sidebar.documentLoader = { [weak owner] key in
      guard let id = key.host.flatMap(UUID.init(uuidString:)),
        let record = owner?.documentStore?.record(id),
        let loader = owner?.inputLoader
      else { return nil }
      return try await loader.load(record, cachedOnly: true)?.document
    }
    sidebar.canSaveSource = { [weak self] key in
      guard let self else { return false }
      return self.currentRecord?.sidebarKey == key && self.source != nil && !self.isLoading
    }
    sidebar.onSourceAction = { [weak self] key, action in
      guard let self, let id = key.host.flatMap(UUID.init(uuidString:)),
        let record = self.store?.record(id)
      else { return }
      switch action {
      case "reload":
        do {
          try self.store?.select(id)
          self.openRecord(id, reload: true)
        } catch { self.appDelegate?.presentInputError(error) }
      case "copy":
        if case .remote(let url) = record.source {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
      case "browser":
        if case .remote(let url) = record.source { NSWorkspace.shared.open(url) }
      case "save": self.saveMarkdownCopy(nil)
      default: break
      }
    }
    sidebar.onToggleOutline = { [weak owner] in owner?.toggleDocumentOutline(nil) }
    sidebar.setOutlineEnabled(owner.outlineEnabled)
    sidebar.onAdd = { [weak owner] in owner?.openDocument(nil) }
    sidebar.onDrop = { [weak self] urls in self?.addDocuments(urls) }
    sidebar.onRemove = { [weak self] in self?.removeSelectedDocument() }
    sidebar.onRemoveAll = { [weak self] in self?.confirmRemoveAllDocuments() }
    sidebar.setSortOrder(
      DocumentSortOrder(rawValue: UserDefaults.standard.string(forKey: "documentSortOrder") ?? "")
        ?? .added)
    sidebar.onSort = { order in
      UserDefaults.standard.set(order.rawValue, forKey: "documentSortOrder")
    }
    let toolbar = NSToolbar(identifier: "ReaderToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    refreshDocuments()
    window.makeFirstResponder(textView)
    showMessage(
      "SSMV",
      detail:
        "So Simple Markdown Viewer.\n\nChoose File → Open… or press ⌘O.\nYou can also open documents from Finder with SSMV."
    )
    if let selected = store?.selectedID { openRecord(selected, cachedOnly: true) }
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

  func refreshDocuments() {
    sidebar.update(records: store?.records ?? [], selectedID: store?.selectedID)
  }

  func openRecord(_ id: UUID, reload: Bool = false, cachedOnly: Bool = false) {
    guard let record = store?.record(id), let loader = appDelegate?.inputLoader else { return }
    if let documentID, displayedID == documentID {
      scrollPositions[documentID] = scrollRestoration.positionToSave(
        current: textView.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    let retaining = documentID == id && source != nil && !isRendering
    if let previous = currentRecord, previous.id != id {
      sidebar.finishPendingDocument(previous.sidebarKey, failed: false)
    }
    if pendingHeading?.documentID != id { pendingHeading = nil }
    documentID = id
    sidebar.selectDocument(record.sidebarKey)
    window?.title = record.displayName
    window?.representedURL = record.originalURL?.isFileURL == true ? record.originalURL : nil
    generation += 1
    let request = generation
    loadTask?.cancel()
    renderTask?.cancel()
    renderGeneration += 1
    isRendering = false
    isLoading = true
    statusLabel.stringValue = "Loading…"
    if !retaining {
      parsed = nil
      source = nil
      snapshotBaseURL = nil
      displayedID = nil
      scrollRestoration.clear()
      showMessage("Opening document…", detail: record.displayName)
    }
    loadTask = Task { [weak self] in
      do {
        let snapshot = try await loader.load(record, reload: reload, cachedOnly: cachedOnly)
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.isLoading = false
        guard let snapshot else {
          self.statusLabel.stringValue = "Not cached — choose Reload to fetch this document."
          self.showMessage(
            "Document not cached", detail: "Choose File → Reload to fetch “\(record.displayName)”.")
          return
        }
        self.parsed = snapshot.document
        self.source = snapshot.source
        self.snapshotBaseURL = snapshot.baseURL
        self.sidebar.provideDocument(snapshot.document, for: record.sidebarKey)
        self.sidebar.updateMetadata(self.store?.records ?? [])
        self.updateSourceStatus()
        self.render(restoring: self.scrollPositions[id] ?? .zero)
      } catch {
        guard let self, !Task.isCancelled, self.generation == request else { return }
        self.isLoading = false
        self.pendingHeading = nil
        if retaining {
          self.statusLabel.stringValue =
            "Reload failed — showing previous content. " + error.localizedDescription
        } else {
          self.sidebar.finishPendingDocument(record.sidebarKey, failed: true)
          self.statusLabel.stringValue = "Couldn’t load document. Choose Reload to retry."
          self.showMessage("Couldn’t open document", detail: error.localizedDescription)
        }
      }
    }
  }

  private func updateSourceStatus() {
    guard let record = currentRecord else {
      statusLabel.stringValue = ""
      return
    }
    if case .remote = record.source, let date = record.lastFetchedAt {
      statusLabel.stringValue =
        "\(record.sourceLabel) · Cached \(date.formatted(date: .abbreviated, time: .shortened)) · ⌘R to refresh"
    } else {
      statusLabel.stringValue = record.sourceLabel
    }
  }

  func addDocuments(_ urls: [URL]) {
    do {
      guard let store else { return }
      try store.addLocal(urls)
      refreshDocuments()
      if let selected = store.selectedID, selected != documentID { openRecord(selected) }
    } catch { appDelegate?.presentInputError(error) }
  }

  private func selectDocument(_ id: UUID) {
    guard id != documentID else { return }
    do {
      try store?.select(id)
      openRecord(id)
    } catch { appDelegate?.presentInputError(error) }
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
    guard !(store?.records.isEmpty ?? true), let window, window.attachedSheet == nil else { return }
    Self.removeAllConfirmation(count: store?.records.count ?? 0).beginSheetModal(for: window) {
      [weak self] response in
      guard response == .alertSecondButtonReturn, let self, !self.isClosing else { return }
      do { try self.store?.removeAllReferences() } catch {
        self.appDelegate?.presentInputError(error)
        return
      }
      self.scrollPositions.removeAll()
      self.removeSelectedDocument()
    }
  }

  @objc func removeSelectedDocument() {
    do {
      if let selected = store?.selectedID {
        scrollPositions.removeValue(forKey: selected)
        try store?.remove(selected)
      }
    } catch {
      appDelegate?.presentInputError(error)
      return
    }
    refreshDocuments()
    if let selected = store?.selectedID {
      openRecord(selected)
    } else {
      generation += 1
      loadTask?.cancel()
      renderTask?.cancel()
      renderGeneration += 1
      isRendering = false
      displayedID = nil
      scrollRestoration.clear()
      parsed = nil
      source = nil
      pendingHeading = nil
      documentID = nil
      snapshotBaseURL = nil
      isLoading = false
      statusLabel.stringValue = ""
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
    guard let parsed, let documentID else { return }
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
              self.displayedID = documentID
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
          self.displayedID = documentID
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

  private func navigateToHeading(_ documentID: UUID, id: Int) {
    pendingHeading = (documentID, id)
    if documentID != self.documentID { selectDocument(documentID) } else { revealPendingHeading() }
  }

  private func revealPendingHeading() {
    guard !isRendering, let pendingHeading, pendingHeading.documentID == displayedID,
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
    guard exportJob == nil, !isRendering, let source, let record = currentRecord, let window else {
      return
    }
    let panel = NSSavePanel()
    panel.title = "Export as PDF"
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = (record.displayName as NSString).deletingPathExtension + ".pdf"
    let baseURL = snapshotBaseURL
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }
      guard self.exportJob == nil else { return }
      let job = PDFExportJob()
      self.exportJob = job
      job.start(
        source: source, fileURL: record.originalURL ?? record.sidebarKey, destination: destination,
        owner: window, documentBaseURL: baseURL, displayName: record.displayName
      ) {
        [weak self] error in
        self?.finishPDFExport(error)
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(confirmRemoveAllDocuments) {
      return !(store?.records.isEmpty ?? true) && window?.attachedSheet == nil
    }
    if menuItem.action == #selector(cancelLoading(_:)) { return isLoading }
    if menuItem.action == #selector(saveMarkdownCopy(_:)) { return source != nil && !isLoading }
    if menuItem.action == #selector(reload(_:)) { return documentID != nil }
    if menuItem.action == #selector(reveal(_:)) {
      if case .localFile = currentRecord?.source { return true }
      return false
    }
    if menuItem.action == #selector(exportPDF(_:)) {
      return source != nil && documentID != nil && !isRendering && exportJob == nil
    }
    return true
  }

  @objc func reload(_ sender: Any?) { if let documentID { openRecord(documentID, reload: true) } }
  @objc func cancelLoading(_ sender: Any?) {
    loadTask?.cancel()
    generation += 1
    isLoading = false
    statusLabel.stringValue =
      source == nil
      ? "Loading cancelled — choose Reload to retry."
      : "Loading cancelled — showing previous content."
  }
  @objc func reveal(_ sender: Any?) {
    if case .localFile(let url) = currentRecord?.source {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
  @objc func saveMarkdownCopy(_ sender: Any?) {
    guard let source, let record = currentRecord, let window else { return }
    let panel = NSSavePanel()
    panel.title = "Save a Markdown Copy"
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue =
      record.displayName.hasSuffix(".md") ? record.displayName : record.displayName + ".md"
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }
      do { try source.write(to: destination, atomically: true, encoding: .utf8) } catch {
        self.appDelegate?.presentInputError(error)
      }
    }
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
      guard case .localFile = currentRecord?.source else { return true }
      appDelegate?.open(url)
    } else if url.scheme == "https",
      ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    {
      appDelegate?.openRemote(url)
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
