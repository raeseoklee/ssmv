import AppKit
import Darwin
import ImageIO

/// WebKit can block synchronously while its process pool starts. A task timeout inside
/// that process cannot run until the main thread unblocks, so snapshot in a child.
@MainActor
final class MermaidPreviewJob {
  static let shared = MermaidPreviewJob()
  private static let maxBytes = 24 * 1024 * 1024
  private let cache = NSCache<NSString, NSImage>()
  private let executable: URL
  private let directory: URL
  private let timeout: Duration
  private var process: Process?
  private var retryAfter = ContinuousClock.now

  // The first WebKit bootstrap can take 45s while macOS power observers time out.
  // Text has already been displayed; allow that cold start without holding the UI.
  init(executable: URL = Bundle.main.executableURL!, directory: URL = FileManager.default.temporaryDirectory,
       timeout: Duration = .seconds(60)) {
    self.executable = executable
    self.directory = directory
    self.timeout = timeout
    cache.countLimit = 24
    cache.totalCostLimit = Self.maxBytes
  }

  var isRunning: Bool { process?.isRunning == true }

  // Unlink each descriptor immediately: neither document contents nor output remain
  // at a reusable path, even if the reader crashes or the child is forcibly stopped.
  private func scratch() throws -> FileHandle {
    let url = directory.appendingPathComponent("ssmv-diagram-" + UUID().uuidString)
    let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard unlink(url.path) == 0 else { try? handle.close(); throw CocoaError(.fileWriteUnknown) }
    return handle
  }

  func image(_ source: String, dark: Bool, width: CGFloat) async -> NSImage? {
    guard !Task.isCancelled, source.utf8.count <= 65_536, width.isFinite else { return nil }
    let width = Int(min(2048, max(100, width)))
    let key = "\(dark):\(width):\(source)" as NSString
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      if let image = cache.object(forKey: key) { return image }
      guard !Task.isCancelled, ContinuousClock.now >= retryAfter, ContinuousClock.now < deadline else { return nil }
      if process == nil { break }
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
    }
    do {
      let input = try scratch(), output = try scratch()
      defer { try? input.close(); try? output.close() }
      try input.write(contentsOf: Data(source.utf8))
      try input.seek(toOffset: 0)
      let child = Process()
      child.executableURL = executable
      child.arguments = ["--render-mermaid-preview", dark ? "dark" : "light", String(width)]
      child.standardInput = input
      child.standardOutput = output
      child.standardError = FileHandle.nullDevice
      try child.run()
      process = child
      // Foundation reaps its Process asynchronously. Retain our slot until it exits,
      // including after SIGKILL, without waiting synchronously on the reader thread.
      defer {
        if child.isRunning {
          kill(child.processIdentifier, SIGKILL)
          Task { @MainActor in
            while child.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
            if self.process === child { self.process = nil }
          }
        } else { process = nil }
      }
      while child.isRunning {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          retryAfter = ContinuousClock.now.advanced(by: .seconds(30))
          return nil
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard !Task.isCancelled, child.terminationStatus == 0,
        try output.seekToEnd() <= UInt64(Self.maxBytes + 64) else { return nil }
      try output.seek(toOffset: 0)
      guard let data = try output.readToEnd(), let split = data.prefix(64).firstIndex(of: 10),
        let header = String(data: data[..<split], encoding: .ascii) else { return nil }
      let size = header.split(separator: " ").compactMap { Double($0) }
      guard size.count == 2, size[0] > 0, size[1] > 0, size[0] <= Double(width), size[1] <= 700 else { return nil }
      let png = data.suffix(from: split + 1)
      guard let source = CGImageSourceCreateWithData(png as CFData, nil),
        CGImageSourceGetType(source) as String? == "public.png",
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let w = properties[kCGImagePropertyPixelWidth] as? Int,
        let h = properties[kCGImagePropertyPixelHeight] as? Int,
        w > 0, h > 0, w <= 4096, h <= 8192, w * h <= Self.maxBytes / 4,
        let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
      let image = NSImage(cgImage: cg, size: NSSize(width: size[0], height: size[1]))
      cache.setObject(image, forKey: key, cost: w * h * 4)
      return image
    } catch { return nil }
  }
}

/// Private mode: bounded input on stdin; logical point size and PNG on stdout.
@MainActor
func runMermaidPreviewHelper(_ arguments: [String]) async -> Int32 {
  guard arguments.count == 4, ["light", "dark"].contains(arguments[2]),
    let width = Int(arguments[3]), (100...2048).contains(width) else { return 2 }
  do {
    guard let bytes = try FileHandle.standardInput.read(upToCount: 65_537), bytes.count <= 65_536,
      let source = String(data: bytes, encoding: .utf8),
      let image = await MermaidRenderer.shared.image(source, dark: arguments[2] == "dark", width: CGFloat(width)),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
      data.count <= 24 * 1024 * 1024 else { return 1 }
    let size = "\(image.size.width) \(image.size.height)\n"
    try FileHandle.standardOutput.write(contentsOf: Data(size.utf8))
    try FileHandle.standardOutput.write(contentsOf: data)
    return 0
  } catch { return 1 }
}
