import AppKit
import Darwin
import Testing

@testable import SSMV

@Suite(.serialized) @MainActor
struct MermaidPreviewJobTests {
  private func fixture(_ script: String) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let helper = root.appendingPathComponent("helper")
    try ("#!/bin/sh\nset -eu\n" + script).write(to: helper, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    return (root, helper)
  }

  @Test func timeoutAndCancellationKillStuckHelperWithoutBlockingReader() async throws {
    for cancel in [false, true] {
      let (root, helper) = try fixture("echo $$ > \"${0%/*}/pid\"\ntrap '' TERM\nexec /bin/sleep 30\n")
      defer { try? FileManager.default.removeItem(at: root) }
      let job = MermaidPreviewJob(executable: helper, directory: root, timeout: cancel ? .seconds(5) : .milliseconds(250))
      let task = Task { @MainActor in await job.image("private contents", dark: false, width: 600) == nil }
      let pidFile = root.appendingPathComponent("pid")
      let until = ContinuousClock.now.advanced(by: .seconds(2))
      while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < until {
        try await Task.sleep(for: .milliseconds(10))
      }
      let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
      #expect(job.isRunning)
      let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
      #expect(names == ["helper", "pid"])  // no document or output file visible even during execution
      if cancel { task.cancel() }
      let start = ContinuousClock.now
      #expect(await task.value)
      while kill(pid, 0) == 0, start.duration(to: .now) < .seconds(2) { try await Task.sleep(for: .milliseconds(10)) }
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
      #expect(start.duration(to: .now) < .seconds(2))
      if !cancel {
        try FileManager.default.removeItem(at: pidFile)
        #expect(await job.image("next diagram", dark: false, width: 600) == nil)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
      }
    }
  }

  @Test func verifiedImageIsReusedAndDocumentsAreNotCommandArguments() async throws {
    let (root, helper) = try fixture("""
    [ "$#" -eq 3 ] && [ "$1" = --render-mermaid-preview ] && [ "$2" = dark ] && [ "$3" = 600 ]
    [ "$(cat)" = 'private fixture' ]
    printf '1 1\\n'
    cat "${0%/*}/fixture.png"
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: root.appendingPathComponent("fixture.png"))
    let job = MermaidPreviewJob(executable: helper, directory: root)
    let image = try #require(await job.image("private fixture", dark: true, width: 600))
    #expect(image.size == NSSize(width: 1, height: 1))
    try FileManager.default.removeItem(at: helper)
    #expect(await job.image("private fixture", dark: true, width: 600) === image)
    #expect(await job.image("private fixture", dark: false, width: 600) == nil)
  }
}
