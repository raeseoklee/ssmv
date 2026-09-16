import AppKit
import MarkdownCore
import UniformTypeIdentifiers

extension DocumentRecord {
  /// A stable UI key, never an IO destination. Existing outline nodes use URL keys.
  var sidebarKey: URL { URL(string: "ssmv-document://" + id.uuidString)! }
  var sourceLabel: String {
    switch source {
    case .localFile(let url): return url.deletingLastPathComponent().path
    case .remote(let url): return url.host ?? "Remote document"
    case .imported: return "Imported text"
    }
  }
  var originalURL: URL? {
    switch source {
    case .localFile(let url), .remote(let url): return url
    case .imported: return nil
    }
  }
}

@MainActor
final class DocumentInputLoader {
  let store: DocumentStore
  let remote = RemoteDocumentLoader()
  init(store: DocumentStore) { self.store = store }

  func load(_ record: DocumentRecord, reload: Bool = false, cachedOnly: Bool = false) async throws
    -> DocumentSnapshot?
  {
    switch record.source {
    case .localFile(let url): return try await DocumentLoader.shared.loadSnapshot(url)
    case .imported:
      guard let url = store.fileURL(for: record) else { throw CocoaError(.fileNoSuchFile) }
      let source = try await Task.detached { try MarkdownDocument.read(url, preservingBOM: true) }
        .value
      try Task.checkCancellation()
      return try await DocumentLoader.shared.parseSnapshot(source: source, baseURL: nil)
    case .remote(let url):
      let content: RemoteDocumentContent
      if cachedOnly {
        guard let cached = try await remote.cached(url) else { return nil }
        content = cached
      } else {
        content = try await remote.load(url, reload: reload)
      }
      try Task.checkCancellation()
      if store.record(record.id) != nil {
        try store.updateRemoteMetadata(
          id: record.id, modifiedAt: content.modifiedAt, fetchedAt: content.fetchedAt)
      }
      var base = URLComponents(
        url: content.resolvedURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false)
      base?.query = nil
      base?.fragment = nil
      return try await DocumentLoader.shared.parseSnapshot(
        source: content.source, baseURL: base?.url)
    }
  }
}

extension AppDelegate {
  func inputViewer() -> ViewerWindow {
    let available = windows.filter { !$0.isClosing }
    let viewer =
      available.first(where: { $0.window?.isKeyWindow == true }) ?? available.first
      ?? ViewerWindow(owner: self)
    if !windows.contains(where: { $0 === viewer }) { windows.append(viewer) }
    return viewer
  }

  func presentInputError(_ error: Error) {
    let alert = NSAlert(error: error)
    if let window = NSApp.keyWindow, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  func openRemote(_ url: URL) {
    do {
      let validated = try RemoteURLPolicy.normalize(url)
      guard let store = documentStore else { throw CocoaError(.fileWriteUnknown) }
      let record = try store.addRemote(validated)
      let viewer = inputViewer()
      viewer.refreshDocuments()
      viewer.openRecord(record.id)
      viewer.showWindow(nil)
    } catch { presentInputError(error) }
  }

  func importMarkdown(_ text: String, title: String? = nil, requestID: UUID? = nil) throws {
    guard let store = documentStore else { throw CocoaError(.fileWriteUnknown) }
    let record = try store.importText(text, title: title, requestID: requestID)
    let viewer = inputViewer()
    viewer.refreshDocuments()
    viewer.openRecord(record.id)
    viewer.showWindow(nil)
  }

  @objc func openURLDocument(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Open Markdown URL"
    alert.informativeText =
      "Enter a public HTTPS Markdown address or GitHub file link. Documents are cached on this Mac; use Reload to fetch changes."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
    field.placeholderString = "https://example.com/document.md"
    alert.accessoryView = field
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      presentInputError(CocoaError(.fileReadUnsupportedScheme))
      return
    }
    openRemote(url)
  }

  @objc func openClipboardDocument(_ sender: Any?) {
    do {
      guard let text = NSPasteboard.general.string(forType: .string) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      try importMarkdown(text)
    } catch { presentInputError(error) }
  }

  @discardableResult
  func consumeRequest(_ url: URL, reportError: Bool = true) -> Error? {
    let key = url.standardizedFileURL
    guard !processedRequests.contains(key) || FileManager.default.fileExists(atPath: key.path)
    else {
      return nil
    }
    do {
      let inbox = OpenRequestInbox()
      let pending = try inbox.consume(url)
      switch pending.request.operation {
      case .remote:
        guard let url = pending.request.url, let store = documentStore else {
          throw CocoaError(.fileReadCorruptFile)
        }
        let record = try store.addRemote(RemoteURLPolicy.normalize(url))
        let viewer = inputViewer()
        viewer.refreshDocuments()
        viewer.openRecord(record.id)
        viewer.showWindow(nil)
      case .importText:
        guard let data = pending.text, let text = String(data: data, encoding: .utf8) else {
          throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        try importMarkdown(text, title: pending.request.title, requestID: pending.request.requestID)
      }
      try inbox.acknowledge(pending)
      processedRequests.insert(key)
      return nil
    } catch {
      if reportError { presentInputError(error) }
      return error
    }
  }

  @objc func retryPendingImports(_ sender: Any?) {
    guard !isRecoveringRequests, documentStore != nil else { return }
    isRecoveringRequests = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.isRecoveringRequests = false }
      do {
        let pending = try OpenRequestInbox().pendingRequests()
        var firstError: Error?
        var failed = 0
        for url in pending {
          if let error = self.consumeRequest(url, reportError: false) {
            firstError = firstError ?? error
            failed += 1
          }
          await Task.yield()
        }
        if let firstError {
          let error = NSError(
            domain: "SSMV.Import", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "\(failed) pending imports could not be opened. \(firstError.localizedDescription) Resolve the problem, then choose File → Retry Pending Imports. Pending requests expire after 24 hours."
            ])
          self.presentInputError(error)
        }
      } catch { self.presentInputError(error) }
    }
  }

  @objc func manageImports(_ sender: Any?) {
    guard let store = documentStore else { return }
    let imports = store.unlistedImports
    let alert = NSAlert()
    alert.messageText = "Manage Imported Documents"
    alert.informativeText =
      "\(imports.count) unlisted documents. Imported text uses \(ByteCountFormatter.string(fromByteCount: Int64(store.importedByteCount), countStyle: .file)) on this Mac. Documents still in the sidebar cannot be deleted here."
    guard !imports.isEmpty else {
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    picker.addItems(withTitles: imports.map { $0.displayName })
    alert.accessoryView = picker
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Save a Copy…")
    alert.addButton(withTitle: "Delete…")
    let response = alert.runModal()
    guard picker.indexOfSelectedItem >= 0 else { return }
    let record = imports[picker.indexOfSelectedItem]
    if response == .alertSecondButtonReturn {
      guard let sourceURL = store.fileURL(for: record) else { return }
      let save = NSSavePanel()
      save.nameFieldStringValue = record.displayName
      save.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
      if save.runModal() == .OK, let destination = save.url {
        do { try Data(contentsOf: sourceURL).write(to: destination, options: .atomic) } catch {
          presentInputError(error)
        }
      }
    } else if response == .alertThirdButtonReturn {
      let confirm = NSAlert()
      confirm.messageText = "Delete “\(record.displayName)”?"
      confirm.informativeText =
        "This permanently deletes the imported copy stored by SSMV. Copies you saved elsewhere are not affected."
      confirm.addButton(withTitle: "Cancel")
      confirm.addButton(withTitle: "Delete")
      confirm.buttons[1].hasDestructiveAction = true
      if confirm.runModal() == .alertSecondButtonReturn {
        do { try store.deleteUnlistedImport(record.id) } catch { presentInputError(error) }
      }
    }
  }
}
