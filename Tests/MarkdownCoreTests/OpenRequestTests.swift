import Foundation
import Testing

@testable import MarkdownCore

struct OpenRequestTests {
  private func withInbox(_ body: (OpenRequestInbox) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(OpenRequestInbox(directory: directory))
  }

  @Test func textRoundTripRetainsUntilAcknowledged() throws {
    try withInbox { inbox in
      let data = Data("# 한국어\nHello".utf8)
      let envelope = try inbox.stageText(data, title: "../../Notes")
      let pending = try inbox.consume(envelope)
      #expect(pending.text == data)
      #expect(pending.request.title == "../../Notes")
      #expect(try inbox.consume(envelope).request.requestID == pending.request.requestID)
      // LaunchServices can return the /private/tmp spelling for a /tmp inbox.
      if envelope.path.hasPrefix("/tmp/") {
        let delivered = URL(fileURLWithPath: "/private" + envelope.path)
        #expect(try inbox.consume(delivered).request.requestID == pending.request.requestID)
      }

      #expect(FileManager.default.fileExists(atPath: envelope.path))
      let attributes = try FileManager.default.attributesOfItem(atPath: envelope.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      try inbox.acknowledge(pending)
      #expect(!FileManager.default.fileExists(atPath: envelope.path))
    }
  }

  @Test func remoteRoundTripAndPolicy() throws {
    try withInbox { inbox in
      let url = URL(string: "https://example.com/doc.md?key=private")!
      let pending = try inbox.consume(inbox.stageRemote(url))
      #expect(pending.request.url == url)
      #expect(pending.text == nil)
      for invalid in [
        "http://example.com/a.md", "https://user:pass@example.com/a.md", "file:///tmp/a.md",
      ] {
        #expect(throws: (any Error).self) { try inbox.stageRemote(URL(string: invalid)!) }
      }
    }
  }

  @Test func inputBoundsAndEncoding() throws {
    try OpenRequestInbox.validateText(Data(repeating: 65, count: OpenRequestInbox.maximumTextBytes))
    for invalid in [
      Data(), Data(" \n\t\u{2003}".utf8), Data([0xff]),
      Data(repeating: 65, count: OpenRequestInbox.maximumTextBytes + 1),
    ] {
      #expect(throws: (any Error).self) { try OpenRequestInbox.validateText(invalid) }
    }
  }

  @Test func rejectsTraversalSymlinksAndVersions() throws {
    try withInbox { inbox in
      let envelope = try inbox.stageText(Data("hello".utf8))
      let request = try inbox.consume(envelope).request
      let payload = inbox.directory.appendingPathComponent(request.payload!)
      try FileManager.default.removeItem(at: payload)
      try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: envelope)
      #expect(throws: (any Error).self) { try inbox.consume(envelope) }
      let bad = OpenRequest(
        version: 2, requestID: request.requestID, operation: .remote,
        url: URL(string: "https://example.com/a.md")!)
      try JSONEncoder().encode(bad).write(to: envelope)
      #expect(throws: OpenRequestError.self) { try inbox.consume(envelope) }
      let traversal = OpenRequest(
        requestID: request.requestID, operation: .importText, payload: "../a.md")
      try JSONEncoder().encode(traversal).write(to: envelope)
      #expect(throws: (any Error).self) { try inbox.consume(envelope) }
      let outside = inbox.directory.deletingLastPathComponent().appendingPathComponent(
        envelope.lastPathComponent)
      #expect(throws: (any Error).self) { try inbox.consume(outside) }
    }
  }

  @Test func concurrentProducersKeepDistinctRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = OpenRequestInbox(directory: directory)
    let urls = try await withThrowingTaskGroup(of: URL.self) { group in
      for index in 0..<10 {
        group.addTask { try inbox.stageText(Data("# Document \(index)".utf8)) }
      }
      var urls: [URL] = []
      for try await url in group { urls.append(url) }
      return urls
    }
    #expect(Set(urls).count == 10)
    for url in urls { #expect(try inbox.consume(url).text != nil) }
  }

  @Test func pendingReplayExcludesUnsafeAndIncompleteFilesAndCapsCount() throws {
    try withInbox { inbox in
      let first = try inbox.stageText(Data("# Pending".utf8))
      let partial = inbox.directory.appendingPathComponent("\(UUID().uuidString).partial")
      try Data("partial".utf8).write(to: partial)
      let symlink = inbox.directory.appendingPathComponent("\(UUID().uuidString).ssmvrequest")
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)
      #expect(try inbox.pendingRequests() == [first])
      #expect(FileManager.default.fileExists(atPath: first.path))
      try FileManager.default.removeItem(at: symlink)
      for _ in 1..<OpenRequestInbox.maximumPendingRequests {
        _ = try inbox.stageRemote(URL(string: "https://example.com/doc.md")!)
      }
      #expect(try inbox.pendingRequests().count == OpenRequestInbox.maximumPendingRequests)
      #expect(throws: OpenRequestError.self) {
        try inbox.stageText(Data("# Over capacity".utf8))
      }
    }
  }

  @Test func expiryPreservesRecentlyClaimedPayload() throws {
    try withInbox { inbox in
      let envelope = try inbox.stageText(Data("hello".utf8))
      let pending = try inbox.consume(envelope)
      let payload = inbox.directory.appendingPathComponent(pending.request.payload!)
      let old = Date().addingTimeInterval(-90_000)
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)
      try inbox.pruneExpired()
      #expect(FileManager.default.fileExists(atPath: payload.path))
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: envelope.path)
      try inbox.pruneExpired()
      #expect(!FileManager.default.fileExists(atPath: payload.path))
      #expect(!FileManager.default.fileExists(atPath: envelope.path))
    }
  }
}
