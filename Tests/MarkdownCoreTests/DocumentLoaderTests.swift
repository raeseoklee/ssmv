import Foundation
import Testing

@testable import MarkdownCore

private final class ControlledParser: @unchecked Sendable {
  private let lock = NSLock()
  private var started: [String] = []
  private var active = 0
  private var maximum = 0
  let release = DispatchSemaphore(value: 0)

  func parse(_ url: URL) throws -> AttributedString {
    let name = url.lastPathComponent
    lock.withLock {
      started.append(name)
      active += 1
      maximum = max(maximum, active)
    }
    defer { lock.withLock { active -= 1 } }
    if name.hasPrefix("blocked") {
      #expect(release.wait(timeout: .now() + 5) == .success, "Blocked parser was not released")
    }
    if name == "error" { throw CocoaError(.fileReadUnknown) }
    return AttributedString(name)
  }

  func hasStarted(_ name: String) -> Bool { lock.withLock { started.contains(name) } }
  var maximumActive: Int { lock.withLock { maximum } }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(condition(), "Timed out waiting for controlled parser")
}

@Test func cancelledParserDoesNotBlockNewDocument() async throws {
  let parser = ControlledParser()
  let loader = DocumentLoader(parser: parser.parse)
  let old = Task { try await loader.load(URL(fileURLWithPath: "/blocked-old")) }
  defer { parser.release.signal() }
  try await waitUntil { parser.hasStarted("blocked-old") }
  old.cancel()
  // This must finish before the blocked synchronous parser is released.
  await #expect(throws: CancellationError.self) { try await old.value }
  let fresh = try await loader.load(URL(fileURLWithPath: "/fresh"))
  #expect(String(fresh.characters) == "fresh")
  #expect(parser.maximumActive == 2)
}

@Test func cancelledQueuedDocumentIsSkippedAndSlotsAreReclaimed() async throws {
  let parser = ControlledParser()
  let loader = DocumentLoader(parser: parser.parse)
  let first = Task { try await loader.load(URL(fileURLWithPath: "/blocked-first")) }
  let second = Task { try await loader.load(URL(fileURLWithPath: "/blocked-second")) }
  defer {
    parser.release.signal()
    parser.release.signal()
  }
  try await waitUntil { parser.hasStarted("blocked-first") && parser.hasStarted("blocked-second") }
  let queued = Task { try await loader.load(URL(fileURLWithPath: "/cancelled")) }
  try await Task.sleep(for: .milliseconds(20))
  queued.cancel()
  await #expect(throws: CancellationError.self) { try await queued.value }
  #expect(!parser.hasStarted("cancelled"))
  parser.release.signal()
  parser.release.signal()
  _ = try await first.value
  _ = try await second.value
  await #expect(throws: CocoaError.self) {
    try await loader.load(URL(fileURLWithPath: "/error"))
  }
  _ = try await loader.load(URL(fileURLWithPath: "/after-error"))
  #expect(!parser.hasStarted("cancelled"))
  #expect(parser.maximumActive <= 2)
}

@Test func alreadyCancelledLoadNeverParses() async throws {
  let parser = ControlledParser()
  let loader = DocumentLoader(parser: parser.parse)
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await loader.load(URL(fileURLWithPath: "/cancelled"))
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(!parser.hasStarted("cancelled"))
}
