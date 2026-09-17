import Foundation
import Testing

@testable import MarkdownCore

@Suite(.serialized)
struct RemoteDocumentLoaderTests {
  private func fixture() throws -> (RemoteDocumentLoader, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteProtocol.self]
    RemoteProtocol.reset()
    return (
      RemoteDocumentLoader(cacheDirectory: directory, sessionConfiguration: configuration),
      directory
    )
  }

  @Test func policyPreservesQueryAndEncodedBranchPath() throws {
    let input = URL(
      string: "HTTPS://GitHub.COM/swiftlang/swift/blob/release/6.1/%52EADME.md?token=secret#heading"
    )!
    let normalized = try RemoteURLPolicy.normalize(input)
    #expect(normalized.host == "github.com")
    #expect(normalized.fragment == nil)
    #expect(normalized.query == "token=secret")
    let resolved = try RemoteURLPolicy.resolvedURL(input)
    #expect(resolved.absoluteString.contains("/blob/release/6.1/%52EADME.md"))
    #expect(resolved.query == "token=secret&raw=true")
    for invalid in [
      "http://example.com/a.md", "https://user:password@example.com/a.md", "file:///tmp/a.md",
    ] {
      #expect(throws: RemoteDocumentError.self) {
        try RemoteURLPolicy.validate(URL(string: invalid)!)
      }
    }
    #expect(throws: RemoteDocumentError.self) {
      try RemoteURLPolicy.resolvedURL(URL(string: "https://github.com/raeseoklee/ssmv")!)
    }
  }

  @Test func cacheIsDiskOnlyAndReloadReplacesSnapshot() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://example.com/document.md?private=value")!
    #expect(try await loader.cached(url) == nil)
    #expect(RemoteProtocol.count == 0)
    let first = try await loader.load(url)
    #expect(first.source == "# Remote\n")
    #expect(first.modifiedAt != nil)
    #expect(first.resolvedURL == url)
    #expect(RemoteProtocol.count == 1)
    _ = try await loader.load(url)
    #expect(RemoteProtocol.count == 1)
    RemoteProtocol.body = Data("# Updated".utf8)
    #expect(try await loader.load(url, reload: true).source == "# Updated")
    #expect(RemoteProtocol.count == 2)
    let restored = RemoteDocumentLoader(cacheDirectory: directory)
    #expect(try await restored.cached(url)?.source == "# Updated")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    #expect(files.filter { $0.pathExtension == "md" }.count == 1)
    #expect(
      !files.contains { $0.lastPathComponent.contains("private") || $0.pathExtension == "partial" })
  }

  @Test func refusesHTTPFailuresAndUnexpected304WithoutCache() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for status in [206, 304, 403, 404, 500] {
      RemoteProtocol.status = status
      await #expect(throws: RemoteDocumentError.self) {
        try await loader.load(URL(string: "https://example.com/\(status).md")!)
      }
    }
  }

  @Test func redirectsCannotDowngradeOrLoop() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let allowed = try await loader.load(URL(string: "https://example.com/redirect.md")!)
    #expect(allowed.resolvedURL.path == "/final.md")
    await #expect(throws: RemoteDocumentError.self) {
      try await loader.load(URL(string: "https://example.com/downgrade.md")!)
    }
    await #expect(throws: RemoteDocumentError.self) {
      try await loader.load(URL(string: "https://example.com/loop.md")!)
    }
  }

  @Test func validatesMIMEEncodingAndDocumentLevelHTML() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://example.com/document.md")!
    RemoteProtocol.mime = "text/html"
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url) }
    RemoteProtocol.mime = "text/plain"
    RemoteProtocol.body = Data("  <!DOCTYPE html><html>Login</html>".utf8)
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url) }
    RemoteProtocol.body = Data([0xFF, 0xFE, 0x80])
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url) }
    RemoteProtocol.body = Data("# Title\n\nSome <b>inline HTML</b>.".utf8)
    RemoteProtocol.mime = "application/octet-stream"
    #expect(try await loader.load(url).source.contains("inline HTML"))
    await #expect(throws: RemoteDocumentError.self) {
      try await loader.load(URL(string: "https://example.com/download")!)
    }
  }

  @Test func enforcesActualBodyLimitWithoutContentLength() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    RemoteProtocol.body = Data(repeating: 0x61, count: RemoteDocumentLoader.maximumBytes)
    let url = URL(string: "https://example.com/limit.md")!
    #expect(try await loader.load(url).source.utf8.count == RemoteDocumentLoader.maximumBytes)
    RemoteProtocol.body = Data(repeating: 0x61, count: RemoteDocumentLoader.maximumBytes + 1)
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url, reload: true) }
    #expect(try await loader.cached(url)?.source.utf8.count == RemoteDocumentLoader.maximumBytes)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    #expect(!files.contains { $0.pathExtension == "partial" })
  }

  @Test func coalescesRequestsWithoutCancellingOtherWaiters() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    RemoteProtocol.delay = 0.15
    let url = URL(string: "https://example.com/shared.md")!
    let first = Task { try await loader.load(url) }
    let second = Task { try await loader.load(url) }
    try await Task.sleep(for: .milliseconds(40))
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(try await second.value.source == "# Remote\n")
    #expect(RemoteProtocol.count == 1)
    let reload1 = Task { try await loader.load(url, reload: true) }
    let reload2 = Task { try await loader.load(url, reload: true) }
    _ = try await (reload1.value, reload2.value)
    #expect(RemoteProtocol.count == 2)
  }

  @Test func networkErrorsDoNotExposeSignedQueries() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      _ = try await loader.load(
        URL(string: "https://example.com/timeout.md?signature=private-secret")!)
      Issue.record("Expected timeout")
    } catch {
      #expect(error is RemoteDocumentError)
      #expect(error.localizedDescription.contains("timed out"))
      #expect(!error.localizedDescription.contains("private-secret"))
      #expect((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] == nil)
    }
  }

  @Test func rejectsTruncatedBodiesAndDecodedOversize() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://example.com/size.md")!
    RemoteProtocol.headers = ["Content-Length": "100"]
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url) }
    RemoteProtocol.headers = ["Content-Length": "128", "Content-Encoding": "gzip"]
    RemoteProtocol.body = Data(repeating: 0x61, count: RemoteDocumentLoader.maximumBytes + 1)
    await #expect(throws: RemoteDocumentError.self) { try await loader.load(url) }
    #expect(try await loader.cached(url) == nil)
  }

  @Test func cancellationRemovesPartialFilesAndBoundsConcurrency() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    RemoteProtocol.delay = 0.15
    let tasks = (0..<8).map { index in
      Task { try await loader.load(URL(string: "https://example.com/\(index).md")!) }
    }
    try await Task.sleep(for: .milliseconds(35))
    tasks[0].cancel()
    tasks[7].cancel()
    for task in tasks { _ = try? await task.value }
    #expect(RemoteProtocol.peak <= 2)
    #expect(RemoteProtocol.count <= 7)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    #expect(!files.contains { $0.pathExtension == "partial" })
  }

  @Test func evictsOldDiskCacheWithoutDiscardingActiveSnapshot() async throws {
    let (loader, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    RemoteProtocol.body = Data(repeating: 0x61, count: RemoteDocumentLoader.maximumBytes)
    let firstURL = URL(string: "https://example.com/0.md")!
    let first = try await loader.load(firstURL)
    for index in 1..<9 {
      _ = try await loader.load(URL(string: "https://example.com/\(index).md")!)
    }
    #expect(try await loader.cached(firstURL) == nil)
    #expect(first.source.utf8.count == RemoteDocumentLoader.maximumBytes)
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey])
    let size = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
    #expect(size <= RemoteDocumentLoader.maximumCacheBytes)
  }
}

private final class RemoteProtocol: URLProtocol, @unchecked Sendable {
  private struct State {
    var body = Data("# Remote\n".utf8)
    var mime = "text/markdown"
    var status = 200
    var delay: TimeInterval = 0
    var headers: [String: String] = [:]
    var count = 0
    var active = 0
    var peak = 0
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var state = State()
  private let instanceLock = NSLock()
  private var finished = false
  static var body: Data {
    get { lock.withLock { state.body } }
    set { lock.withLock { state.body = newValue } }
  }
  static var mime: String {
    get { lock.withLock { state.mime } }
    set { lock.withLock { state.mime = newValue } }
  }
  static var status: Int {
    get { lock.withLock { state.status } }
    set { lock.withLock { state.status = newValue } }
  }
  static var delay: TimeInterval {
    get { lock.withLock { state.delay } }
    set { lock.withLock { state.delay = newValue } }
  }
  static var headers: [String: String] {
    get { lock.withLock { state.headers } }
    set { lock.withLock { state.headers = newValue } }
  }
  static var count: Int { lock.withLock { state.count } }
  static var peak: Int { lock.withLock { state.peak } }
  static func reset() { lock.withLock { state = State() } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let snapshot = Self.lock.withLock {
      Self.state.count += 1
      Self.state.active += 1
      Self.state.peak = max(Self.state.peak, Self.state.active)
      return Self.state
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + snapshot.delay) { [self] in
      instanceLock.lock()
      guard !finished else {
        instanceLock.unlock()
        return
      }
      if request.url!.path == "/timeout.md" {
        finished = true
        Self.lock.withLock { Self.state.active -= 1 }
        instanceLock.unlock()
        client?.urlProtocol(
          self,
          didFailWithError: URLError(
            .timedOut,
            userInfo: [NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString]))
        return
      }
      if ["/redirect.md", "/downgrade.md", "/loop.md"].contains(request.url!.path) {
        let target: URL
        switch request.url!.path {
        case "/redirect.md": target = URL(string: "https://example.com/final.md")!
        case "/downgrade.md": target = URL(string: "http://example.com/final.md")!
        default: target = request.url!
        }
        finished = true
        Self.lock.withLock { Self.state.active -= 1 }
        instanceLock.unlock()
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
          headerFields: ["Location": target.absoluteString])!
        client?.urlProtocol(
          self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        return
      }
      var headers = [
        "Content-Type": snapshot.mime, "Last-Modified": "Wed, 16 Sep 2026 06:00:00 GMT",
      ]
      headers.merge(snapshot.headers) { _, new in new }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: snapshot.status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for offset in stride(from: 0, to: snapshot.body.count, by: 65536) {
        client?.urlProtocol(
          self,
          didLoad: snapshot.body.subdata(in: offset..<min(offset + 65536, snapshot.body.count)))
      }
      finished = true
      Self.lock.withLock { Self.state.active -= 1 }
      client?.urlProtocolDidFinishLoading(self)
      instanceLock.unlock()
    }
  }
  override func stopLoading() {
    instanceLock.withLock {
      if !finished {
        finished = true
        Self.lock.withLock { Self.state.active -= 1 }
      }
    }
  }
}
