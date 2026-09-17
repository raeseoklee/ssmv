import AppKit
import Foundation

/// Compile with MarkdownCore sources in release mode; see CONTRIBUTING.md.
@main
struct Benchmark {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count >= 2 else {
      print("Usage: benchmark <document.md> [--full-layout]")
      return
    }
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
    view.isEditable = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainerInset = NSSize(width: 36, height: 28)
    view.textContainer?.containerSize = NSSize(width: 688, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.layoutManager?.allowsNonContiguousLayout = true
    view.layoutManager?.backgroundLayoutEnabled = false

    let start = ContinuousClock.now
    func seconds(since start: ContinuousClock.Instant) -> Double {
      let d = start.duration(to: .now).components
      return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
    func report(_ value: String) {
      FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }
    var maxHeartbeatGap = 0.0
    var heartbeatCount = 0
    let heartbeat = Task { @MainActor in
      var last = ContinuousClock.now
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        maxHeartbeatGap = max(maxHeartbeatGap, seconds(since: last))
        heartbeatCount += 1
        last = .now
      }
    }
    defer { heartbeat.cancel() }
    do {
      let parsed = try await DocumentLoader.shared.load(url)
      report("read_parse_s=\(seconds(since: start))")
      let renderStart = ContinuousClock.now
      var chunks = 0
      var maxAppend = 0.0
      try await MarkdownRenderer.renderIncrementally(parsed, size: 16) { chunk in
        let appendStart = ContinuousClock.now
        autoreleasepool {
          view.textStorage?.beginEditing()
          view.textStorage?.append(chunk)
          view.textStorage?.endEditing()
          if chunks == 0, let container = view.textContainer {
            view.layoutManager?.ensureLayout(
              forBoundingRect: NSRect(x: 0, y: 0, width: 688, height: 600), in: container)
          }
        }
        maxAppend = max(maxAppend, seconds(since: appendStart))
        if chunks == 0 { report("first_viewport_s=\(seconds(since: start))") }
        chunks += 1
      }
      let renderSeconds = seconds(since: renderStart)
      // Let the heartbeat observe the last render slice before stopping it.
      try await Task.sleep(for: .milliseconds(12))
      heartbeat.cancel()
      report("render_s=\(renderSeconds)")
      report("ready_s=\(seconds(since: start))")
      report("max_main_heartbeat_gap_s=\(maxHeartbeatGap)")
      report("max_append_s=\(maxAppend)")
      report("heartbeat_count=\(heartbeatCount)")
      report("chunks=\(chunks)")
      report("characters=\(view.textStorage?.length ?? 0)")
      report("tail_preserved=\(view.string.hasSuffix("END_OF_DOCUMENT"))")
      if CommandLine.arguments.contains("--full-layout"), let container = view.textContainer {
        let layoutStart = ContinuousClock.now
        autoreleasepool { view.layoutManager?.ensureLayout(for: container) }
        report("full_layout_s=\(seconds(since: layoutStart))")
      }
      report("status=ok")
    } catch {
      report("status=rejected")
      report("error=\(error.localizedDescription)")
    }
  }
}
