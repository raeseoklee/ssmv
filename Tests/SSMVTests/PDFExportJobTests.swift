import AppKit
import PDFKit
import Testing

@testable import SSMV

private final class TestBundleMarker: NSObject {}

@Suite(.serialized) @MainActor
struct PDFExportJobTests {
  private func fixture() throws -> (URL, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    // SwiftPM builds the executable beside its test bundle in debug and release builds.
    let executable = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("SSMV")
    return (root, executable)
  }

  @Test func exportsSnapshotAndReplacesDestination() async throws {
    let (root, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("changed.md")
    let output = root.appendingPathComponent("result.pdf")
    try "LATERDISKCONTENT".write(to: input, atomically: true, encoding: .utf8)
    try Data("original destination".utf8).write(to: output)
    try await PDFExportJob().run(
      source: "# SNAPSHOTCONTENT\n\nENDMARKER", fileURL: input,
      destination: output, executable: executable, temporaryDirectory: root)
    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.string?.contains("SNAPSHOTCONTENT") == true)
    #expect(pdf.string?.contains("ENDMARKER") == true)
    #expect(pdf.string?.contains("LATERDISKCONTENT") == false)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [
        "changed.md", "result.pdf",
      ])
  }

  @Test func cancellingBusyHelperPreservesDestinationAndReturnsPromptly() async throws {
    let (root, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("result.pdf")
    let original = Data("original destination".utf8)
    try original.write(to: output)
    let job = PDFExportJob()
    let task = Task {
      try await job.run(
        source: String(repeating: "## Heading\n\nText **bold** and `code`.\n\n", count: 150_000),
        fileURL: root.appendingPathComponent("source.md"), destination: output,
        executable: executable, temporaryDirectory: root)
    }
    let deadline = Date().addingTimeInterval(5)
    while !job.isRunning && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(job.isRunning)
    try await Task.sleep(for: .milliseconds(150))
    let start = Date()
    task.cancel()
    do {
      try await task.value
      Issue.record("Export unexpectedly completed")
    } catch is CancellationError {}
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(try Data(contentsOf: output) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result.pdf"])
  }

  @Test func failedHelperPreservesDestinationAndCleansTemporaryFiles() async throws {
    let (root, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("result.pdf")
    let original = Data("original destination".utf8)
    try original.write(to: output)
    do {
      try await PDFExportJob().run(
        source: String(repeating: "x", count: 16 * 1024 * 1024 + 1),
        fileURL: root.appendingPathComponent("source.md"), destination: output,
        executable: executable, temporaryDirectory: root)
      Issue.record("Oversized helper input unexpectedly succeeded")
    } catch {}
    #expect(try Data(contentsOf: output) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result.pdf"])
  }

  @Test func failedLaunchPreservesDestination() async throws {
    let (root, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("result.pdf")
    let original = Data("original destination".utf8)
    try original.write(to: output)
    do {
      try await PDFExportJob().run(
        source: "test", fileURL: root.appendingPathComponent("source.md"),
        destination: output, executable: root.appendingPathComponent("missing"),
        temporaryDirectory: root)
      Issue.record("Missing executable unexpectedly ran")
    } catch {}
    #expect(try Data(contentsOf: output) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result.pdf"])
  }
}
