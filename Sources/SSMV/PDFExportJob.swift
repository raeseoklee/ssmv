import AppKit
import MarkdownCore

/// Keeps AppKit's synchronous print layout outside the interactive app process.
@MainActor
final class PDFExportJob {
  private var process: Process?
  private var task: Task<Void, Never>?
  private var panel: NSPanel?
  private let status = NSTextField(labelWithString: "Preparing document…")

  func start(
    source: String, fileURL: URL, destination: URL, owner: NSWindow,
    completion: @escaping @MainActor (Error?) -> Void
  ) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
      styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.title = "Exporting PDF"
    panel.isReleasedWhenClosed = false
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.startAnimation(nil)
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelExport))
    cancel.keyEquivalent = "\u{1b}"
    let name = NSTextField(labelWithString: fileURL.lastPathComponent)
    name.lineBreakMode = .byTruncatingMiddle
    let row = NSStackView(views: [spinner, status])
    row.orientation = .horizontal
    let stack = NSStackView(views: [name, row, cancel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
    ])
    panel.setFrameOrigin(NSPoint(x: owner.frame.midX - 180, y: owner.frame.midY - 65))
    owner.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    self.panel = panel
    task = Task {
      var failure: Error?
      do {
        try await run(source: source, fileURL: fileURL, destination: destination)
      } catch is CancellationError {} catch { failure = error }
      owner.removeChildWindow(panel)
      panel.close()
      self.panel = nil
      self.task = nil
      completion(failure)
    }
  }

  @objc func cancelExport() {
    status.stringValue = "Cancelling…"
    task?.cancel()
    if let process, process.isRunning { process.terminate() }
  }

  var isRunning: Bool { process?.isRunning == true }

  func run(
    source: String, fileURL: URL, destination: URL,
    executable: URL = Bundle.main.executableURL!,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) async throws {
    try Task.checkCancellation()
    let directory =
      temporaryDirectory
      .appendingPathComponent("ssmv-export-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("source.md")
    let output = directory.appendingPathComponent("document.pdf")
    let progress = directory.appendingPathComponent("progress")
    // A snapshot avoids exporting later on-disk edits or another selected document.
    try await Task.detached {
      try Data(source.utf8).write(to: input, options: .atomic)
    }.value
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--export-pdf", input.path, fileURL.deletingLastPathComponent().absoluteString,
      output.path, fileURL.lastPathComponent, progress.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    self.process = process
    defer { self.process = nil }
    let progressTask = Task {
      while !Task.isCancelled {
        if let stage = try? String(contentsOf: progress, encoding: .utf8),
          ["Reading document…", "Formatting document…", "Laying out pages…", "Writing PDF…"]
            .contains(stage)
        {
          status.stringValue = stage
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
    defer { progressTask.cancel() }
    let exitStatus: Int32 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { finished in
          continuation.resume(returning: finished.terminationStatus)
        }
        do { try process.run() } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Task { @MainActor in
        if process.isRunning { process.terminate() }
      }
    }
    try Task.checkCancellation()
    guard exitStatus == 0 else { throw PDFExporter.ExportError.failed }
    // Stage beside the destination for atomic replacement even across volumes.
    let staged = destination.deletingLastPathComponent()
      .appendingPathComponent(".ssmv-" + UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: staged) }
    try await Task.detached { try FileManager.default.copyItem(at: output, to: staged) }.value
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
    } else {
      try FileManager.default.moveItem(at: staged, to: destination)
    }
  }
}

/// This private mode has no windows, menus, or Launch Services registration.
@MainActor
func runPDFExportHelper(_ arguments: [String]) -> Int32 {
  guard arguments.count == 7, let baseURL = URL(string: arguments[3]), baseURL.isFileURL else {
    return 2
  }
  let progress = URL(fileURLWithPath: arguments[6])
  func report(_ stage: String) { try? stage.write(to: progress, atomically: true, encoding: .utf8) }
  do {
    report("Reading document…")
    let source = try MarkdownDocument.read(URL(fileURLWithPath: arguments[2]))
    let document = try MarkdownDocument.parse(source, baseURL: baseURL)
    try PDFExporter.export(
      document, title: arguments[5],
      to: URL(fileURLWithPath: arguments[4]), progress: report)
    return 0
  } catch { return 1 }
}
