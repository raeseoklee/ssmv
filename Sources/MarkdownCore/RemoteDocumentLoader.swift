import CryptoKit
import Foundation

public struct RemoteDocumentContent: Sendable {
  public let source: String
  public let resolvedURL: URL
  public let fetchedAt: Date
  public let modifiedAt: Date?

  public init(source: String, resolvedURL: URL, fetchedAt: Date, modifiedAt: Date?) {
    self.source = source
    self.resolvedURL = resolvedURL
    self.fetchedAt = fetchedAt
    self.modifiedAt = modifiedAt
  }
}

public enum RemoteDocumentError: LocalizedError, Sendable {
  case invalidURL, unsupportedGitHubURL
  case httpStatus(Int)
  case tooLarge, invalidEncoding
  case unsupportedContent, tooManyRedirects, incompleteResponse, timedOut, networkFailure

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "Use an HTTPS address without a username or password."
    case .unsupportedGitHubURL: "Open a GitHub file page or copy the file's Raw URL."
    case .httpStatus(let status): "The server returned HTTP \(status). Use a public Markdown URL."
    case .tooLarge: "The remote document exceeds the 16 MiB limit."
    case .invalidEncoding: "The remote document is not valid UTF-8 text."
    case .unsupportedContent:
      "This address returned a webpage or unsupported content. Copy a raw Markdown URL."
    case .tooManyRedirects:
      "The address redirected too many times. Copy the final raw Markdown URL."
    case .incompleteResponse: "The server returned an incomplete document. Try reloading."
    case .timedOut: "The download timed out. Try reloading."
    case .networkFailure:
      "The document could not be downloaded. Check your connection and try reloading."
    }
  }
}

public enum RemoteURLPolicy {
  public static func validate(_ url: URL) throws {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, url.absoluteString.utf8.count <= 8192
    else { throw RemoteDocumentError.invalidURL }
  }

  public static func normalize(_ url: URL) throws -> URL {
    try validate(url)
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.scheme = "https"
    parts.host = parts.host?.lowercased()
    parts.fragment = nil
    guard let result = parts.url else { throw RemoteDocumentError.invalidURL }
    return result
  }

  /// Let GitHub resolve the entire blob path, including refs containing slashes.
  public static func resolvedURL(_ url: URL) throws -> URL {
    let normalized = try normalize(url)
    guard normalized.host?.lowercased() == "github.com" else { return normalized }
    let segments = normalized.path.split(separator: "/")
    guard segments.count >= 5, ["blob", "raw"].contains(String(segments[2])) else {
      throw RemoteDocumentError.unsupportedGitHubURL
    }
    if segments[2] == "raw" { return normalized }
    var parts = URLComponents(url: normalized, resolvingAgainstBaseURL: false)!
    var query = parts.queryItems ?? []
    query.removeAll { $0.name == "raw" }
    query.append(URLQueryItem(name: "raw", value: "true"))
    parts.queryItems = query
    return parts.url!
  }
}

/// Acquires source bytes only. Parsing remains in the separately bounded document loader.
public actor RemoteDocumentLoader {
  public static let maximumBytes = 16 * 1024 * 1024
  public static let maximumCacheBytes = 128 * 1024 * 1024
  private let directory: URL
  private let configuration: URLSessionConfiguration
  private var active = 0
  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
    var waiters: [UUID: Waiter]
  }
  private var flights: [String: Flight] = [:]

  public init(
    cacheDirectory: URL? = nil, sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) {
    directory =
      cacheDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("io.github.irae.ssmv/RemoteDocuments", isDirectory: true)
    configuration = sessionConfiguration.copy() as! URLSessionConfiguration
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.httpMaximumConnectionsPerHost = 2
  }

  /// A disk-only lookup: restoring or expanding an inactive document never starts networking.
  public func cached(_ url: URL) throws -> RemoteDocumentContent? {
    let key = try cacheKey(url)
    let metadataURL = directory.appendingPathComponent(key + ".json")
    guard let data = Self.metadataData(at: metadataURL),
      var metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data),
      UUID(uuidString: metadata.body) != nil
    else { return nil }
    let bodyURL = directory.appendingPathComponent(metadata.body + ".md")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: bodyURL.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? Int, size <= Self.maximumBytes,
      let body = try? Data(contentsOf: bodyURL),
      let source = String(data: body, encoding: .utf8),
      (try? RemoteURLPolicy.validate(metadata.resolvedURL)) != nil
    else { return nil }
    metadata.accessedAt = Date()
    try? writeMetadata(metadata, to: metadataURL)
    return RemoteDocumentContent(
      source: source, resolvedURL: metadata.resolvedURL,
      fetchedAt: metadata.fetchedAt, modifiedAt: metadata.modifiedAt)
  }

  public func load(_ url: URL, reload: Bool = false) async throws -> RemoteDocumentContent {
    try Task.checkCancellation()
    let requestURL = try RemoteURLPolicy.resolvedURL(url)
    if !reload, let content = try cached(url) { return content }
    let key = try cacheKey(url)
    let waiter = Waiter()
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard waiter.install(continuation) else { return }
        if flights[key] != nil {
          flights[key]?.waiters[waiterID] = waiter
        } else {
          let flightID = UUID()
          let task = Task {
            let result: Swift.Result<RemoteDocumentContent, Error>
            do { result = .success(try await self.acquire(requestURL, key: key)) } catch {
              result = .failure(error)
            }
            self.completed(key: key, flightID: flightID, result: result)
          }
          flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: waiter])
        }
      }
    } onCancel: {
      waiter.finish(.failure(CancellationError()))
      Task { await self.removeWaiter(key: key, id: waiterID) }
    }
  }

  private func removeWaiter(key: String, id: UUID) {
    guard flights[key]?.waiters.removeValue(forKey: id) != nil else { return }
    if flights[key]?.waiters.isEmpty == true {
      flights.removeValue(forKey: key)?.task.cancel()
    }
  }

  private func completed(
    key: String, flightID: UUID,
    result: Swift.Result<RemoteDocumentContent, Error>
  ) {
    guard flights[key]?.id == flightID, let flight = flights.removeValue(forKey: key) else {
      return
    }
    for waiter in flight.waiters.values { waiter.finish(result) }
  }

  private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteDocumentContent, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<RemoteDocumentContent, Error>) -> Bool {
      let accepted = lock.withLock {
        guard !finished else { return false }
        self.continuation = continuation
        return true
      }
      if !accepted { continuation.resume(throwing: CancellationError()) }
      return accepted
    }

    func finish(_ result: Swift.Result<RemoteDocumentContent, Error>) {
      let continuation = lock.withLock {
        guard !finished else { return nil as CheckedContinuation<RemoteDocumentContent, Error>? }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(with: result)
    }
  }

  private func acquire(_ requestURL: URL, key: String) async throws -> RemoteDocumentContent {
    // Waiting tasks remain cancellable, and no timer survives the requesting task.
    while active >= 2 { try await Task.sleep(for: .milliseconds(20)) }
    try Task.checkCancellation()
    active += 1
    defer { active -= 1 }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let transfer = RemoteTransfer(directory: directory, configuration: configuration)
    let result: RemoteTransfer.Result
    do { result = try await transfer.fetch(requestURL) } catch let error as URLError {
      // Never expose Foundation error userInfo, which can include signed query URLs.
      throw error.code == .timedOut
        ? RemoteDocumentError.timedOut : RemoteDocumentError.networkFailure
    }
    defer { try? FileManager.default.removeItem(at: result.file) }
    try Task.checkCancellation()
    let data = try Data(contentsOf: result.file)
    guard let source = String(data: data, encoding: .utf8) else {
      throw RemoteDocumentError.invalidEncoding
    }
    let beginning = source.prefix(1024).trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
    )
    .lowercased()
    guard !beginning.hasPrefix("<!doctype html"), !beginning.hasPrefix("<html"),
      !beginning.hasPrefix("<head"), !beginning.hasPrefix("<body")
    else { throw RemoteDocumentError.unsupportedContent }
    let content = RemoteDocumentContent(
      source: source, resolvedURL: result.response.url!,
      fetchedAt: Date(),
      modifiedAt: Self.httpDate(result.response.value(forHTTPHeaderField: "Last-Modified")))
    try store(content, bodyFile: result.file, key: key)
    return content
  }

  private struct CacheMetadata: Codable {
    let body: String
    let resolvedURL: URL
    let fetchedAt: Date
    let modifiedAt: Date?
    var accessedAt: Date
  }

  private func cacheKey(_ url: URL) throws -> String {
    SHA256.hash(data: Data(try RemoteURLPolicy.normalize(url).absoluteString.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func writeMetadata(_ metadata: CacheMetadata, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    try encoder.encode(metadata).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func store(_ content: RemoteDocumentContent, bodyFile: URL, key: String) throws {
    let name = UUID().uuidString
    let body = directory.appendingPathComponent(name + ".md")
    try FileManager.default.moveItem(at: bodyFile, to: body)
    let metadata = CacheMetadata(
      body: name, resolvedURL: content.resolvedURL,
      fetchedAt: content.fetchedAt, modifiedAt: content.modifiedAt, accessedAt: Date())
    do { try writeMetadata(metadata, to: directory.appendingPathComponent(key + ".json")) } catch {
      try? FileManager.default.removeItem(at: body)
      throw error
    }
    try evict()
  }

  private func evict() throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
    // A prior process may have exited mid-download. Active transfers cannot reach this age.
    for file in files where file.pathExtension == "partial" {
      if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
        modified < Date().addingTimeInterval(-300)
      {
        try? FileManager.default.removeItem(at: file)
      }
    }
    var entries: [(URL, CacheMetadata, Int)] = []
    for file in files where file.pathExtension == "json" {
      guard let data = Self.metadataData(at: file),
        let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data),
        UUID(uuidString: metadata.body) != nil
      else { continue }
      let body = directory.appendingPathComponent(metadata.body + ".md")
      let size = (try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      entries.append((file, metadata, size + data.count))
    }
    let referenced = Set(entries.map { $0.1.body + ".md" })
    // Remove superseded body revisions; snapshots own source strings, never these files.
    for file in files
    where file.pathExtension == "md" && !referenced.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
    var total = entries.reduce(0) { $0 + $1.2 }
    for (file, metadata, size) in entries.sorted(by: { $0.1.accessedAt < $1.1.accessedAt }) {
      guard total > Self.maximumCacheBytes else { break }
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(
        at: directory.appendingPathComponent(metadata.body + ".md"))
      total -= size
    }
  }

  private static func metadataData(at url: URL) -> Data? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? Int, size <= 16_384
    else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func httpDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }
}

/// Delegate callbacks execute serially and stream chunks to disk, not one Swift call per byte.
private final class RemoteTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  struct Result: Sendable {
    let file: URL
    let response: HTTPURLResponse
  }
  private let configuration: URLSessionConfiguration
  private let file: URL
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var continuation: CheckedContinuation<Result, Error>?
  private var handle: FileHandle?
  private var response: HTTPURLResponse?
  private var failure: Error?
  private var byteCount = 0
  private var redirectCount = 0

  init(directory: URL, configuration: URLSessionConfiguration) {
    self.configuration = configuration
    file = directory.appendingPathComponent(UUID().uuidString + ".partial")
  }

  func fetch(_ url: URL) async throws -> Result {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        do {
          guard
            FileManager.default.createFile(
              atPath: file.path, contents: nil,
              attributes: [.posixPermissions: 0o600])
          else { throw CocoaError(.fileWriteUnknown) }
          handle = try FileHandle(forWritingTo: file)
        } catch {
          continuation.resume(throwing: error)
          return
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
          "text/markdown, text/plain, application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("SSMV", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        let cancelled = lock.withLock {
          self.task = task
          return self.cancelled
        }
        if cancelled { task.cancel() }
        task.resume()
        session.finishTasksAndInvalidate()
      }
    } onCancel: {
      self.lock.withLock {
        self.cancelled = true
        self.task?.cancel()
      }
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    do {
      redirectCount += 1
      guard redirectCount <= 5 else { throw RemoteDocumentError.tooManyRedirects }
      guard let url = request.url else { throw RemoteDocumentError.invalidURL }
      try RemoteURLPolicy.validate(url)
      var safeRequest = request
      safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
      safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
      completionHandler(safeRequest)
    } catch {
      failure = error
      completionHandler(nil)
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let response = response as? HTTPURLResponse, let url = response.url else {
        throw RemoteDocumentError.incompleteResponse
      }
      try RemoteURLPolicy.validate(url)
      guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
        throw RemoteDocumentError.incompleteResponse
      }
      guard response.statusCode == 200 else {
        throw RemoteDocumentError.httpStatus(response.statusCode)
      }
      guard response.expectedContentLength <= RemoteDocumentLoader.maximumBytes else {
        throw RemoteDocumentError.tooLarge
      }
      let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
      let markdownExtension = ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
      guard
        mime == "text/plain" || mime == "text/markdown"
          || (mime == "application/octet-stream" && markdownExtension)
      else { throw RemoteDocumentError.unsupportedContent }
      self.response = response
      completionHandler(.allow)
    } catch {
      failure = error
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    guard data.count <= RemoteDocumentLoader.maximumBytes - byteCount else {
      failure = RemoteDocumentError.tooLarge
      dataTask.cancel()
      return
    }
    do {
      try handle?.write(contentsOf: data)
      byteCount += data.count
    } catch {
      failure = error
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    try? handle?.close()
    handle = nil
    let cancelled = lock.withLock {
      self.task = nil
      return self.cancelled
    }
    if failure == nil, let response,
      response.expectedContentLength >= 0,
      response.value(forHTTPHeaderField: "Content-Encoding") == nil,
      response.expectedContentLength != Int64(byteCount)
    {
      failure = RemoteDocumentError.incompleteResponse
    }
    let finalError = failure ?? (cancelled ? CancellationError() : error)
    if let finalError {
      try? FileManager.default.removeItem(at: file)
      continuation?.resume(throwing: finalError)
    } else if let response {
      continuation?.resume(returning: Result(file: file, response: response))
    } else {
      try? FileManager.default.removeItem(at: file)
      continuation?.resume(throwing: RemoteDocumentError.incompleteResponse)
    }
    continuation = nil
  }
}
