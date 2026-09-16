import Darwin
import Foundation

public struct OpenRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case remote, importText }
  public let version: Int
  public let requestID: UUID
  public let operation: Operation
  public let url: URL?
  public let payload: String?
  public let title: String?

  public init(
    version: Int = 1, requestID: UUID = UUID(), operation: Operation,
    url: URL? = nil, payload: String? = nil, title: String? = nil
  ) {
    self.version = version
    self.requestID = requestID
    self.operation = operation
    self.url = url
    self.payload = payload
    self.title = title
  }
}

public struct PendingOpenRequest: Sendable {
  public let request: OpenRequest
  public let text: Data?
  public let envelopeURL: URL
}

public enum OpenRequestError: Error, LocalizedError {
  case invalid, unsupportedVersion, empty, oversized, encoding, capacity
  public var errorDescription: String? {
    switch self {
    case .invalid: "Invalid or unsafe SSMV request."
    case .unsupportedVersion:
      "Unsupported SSMV request version. Update SSMV and its command together."
    case .empty: "No Markdown text."
    case .oversized: "Markdown input exceeds 16 MiB."
    case .encoding: "Markdown input must be valid UTF-8."
    case .capacity: "The SSMV inbox is full. Open SSMV to process pending documents."
    }
  }
}

/// Private, bounded, file-based delivery. Reading does not consume a request;
/// acknowledge only after its source is safely adopted into durable storage.
public struct OpenRequestInbox: Sendable {
  public static let maximumTextBytes = 16 * 1024 * 1024
  public static let maximumEnvelopeBytes = 8192
  public static let maximumPendingBytes = 256 * 1024 * 1024
  public static let maximumPendingRequests = 256
  public let directory: URL

  public init(directory: URL? = nil) {
    self.directory =
      (directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("SSMV/Inbox", isDirectory: true))
      .standardizedFileURL
  }

  public static func validateText(_ data: Data) throws {
    guard !data.isEmpty else { throw OpenRequestError.empty }
    guard data.count <= maximumTextBytes else { throw OpenRequestError.oversized }
    guard let text = String(data: data, encoding: .utf8) else { throw OpenRequestError.encoding }
    guard text.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
    else {
      throw OpenRequestError.empty
    }
  }

  public static func validateURL(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 4096
    else { throw OpenRequestError.invalid }
  }

  public func stageRemote(_ url: URL) throws -> URL {
    try Self.validateURL(url)
    return try stage(OpenRequest(operation: .remote, url: url), data: nil)
  }

  public func stageText(_ data: Data, title: String? = nil) throws -> URL {
    try Self.validateText(data)
    guard title == nil || title!.utf8.count <= 1024 else { throw OpenRequestError.invalid }
    let id = UUID()
    return try stage(
      OpenRequest(
        requestID: id, operation: .importText,
        payload: "\(id.uuidString).md", title: title), data: data)
  }

  private func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
      throw OpenRequestError.invalid
    }
    // Resolve every ancestor too: a symbolic-link parent cannot redirect this inbox.
    guard directory.resolvingSymlinksInPath().path == directory.path else {
      throw OpenRequestError.invalid
    }
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
    else { throw OpenRequestError.invalid }
  }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    try prepare()
    let lockURL = directory.appendingPathComponent(".lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw OpenRequestError.invalid }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0
    else { throw OpenRequestError.invalid }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  private func stage(_ request: OpenRequest, data: Data?) throws -> URL {
    try locked {
      try pruneUnlocked()
      let encoded = try JSONEncoder().encode(request)
      guard encoded.count <= Self.maximumEnvelopeBytes else { throw OpenRequestError.invalid }
      let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey])
      let used = try files.reduce(0) { count, url in
        count + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      }
      guard files.filter({ $0.pathExtension == "ssmvrequest" }).count < Self.maximumPendingRequests,
        used + encoded.count + (data?.count ?? 0) <= Self.maximumPendingBytes
      else {
        throw OpenRequestError.capacity
      }
      let envelope = directory.appendingPathComponent("\(request.requestID.uuidString).ssmvrequest")
      let payloadURL = request.payload.map { directory.appendingPathComponent($0) }
      do {
        if let data, let payloadURL { try write(data, to: payloadURL) }
        try write(encoded, to: envelope)
        return envelope
      } catch {
        if let payloadURL { try? FileManager.default.removeItem(at: payloadURL) }
        throw error
      }
    }
  }

  private func write(_ data: Data, to url: URL) throws {
    let temporary = directory.appendingPathComponent("\(UUID().uuidString).partial")
    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw OpenRequestError.invalid }
    defer {
      close(fd)
      try? FileManager.default.removeItem(at: temporary)
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw OpenRequestError.invalid }
        offset += count
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
      throw OpenRequestError.invalid
    }
  }

  private func read(_ url: URL, limit: Int) throws -> Data {
    guard url.isFileURL, url.standardizedFileURL.deletingLastPathComponent() == directory,
      !url.pathComponents.contains(".."), !url.pathComponents.contains(".")
    else { throw OpenRequestError.invalid }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw OpenRequestError.invalid }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size <= limit
    else { throw OpenRequestError.invalid }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw OpenRequestError.invalid }
      if count == 0 { break }
      guard data.count + count <= limit else { throw OpenRequestError.invalid }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  public func consume(_ envelopeURL: URL) throws -> PendingOpenRequest {
    try locked {
      let request = try JSONDecoder().decode(
        OpenRequest.self,
        from: read(envelopeURL, limit: Self.maximumEnvelopeBytes))
      guard request.version == 1 else { throw OpenRequestError.unsupportedVersion }
      guard envelopeURL.lastPathComponent == "\(request.requestID.uuidString).ssmvrequest" else {
        throw OpenRequestError.invalid
      }
      var text: Data?
      switch request.operation {
      case .remote:
        guard let url = request.url, request.payload == nil, request.title == nil else {
          throw OpenRequestError.invalid
        }
        try Self.validateURL(url)
      case .importText:
        guard request.url == nil, request.payload == "\(request.requestID.uuidString).md",
          request.title == nil || request.title!.utf8.count <= 1024
        else { throw OpenRequestError.invalid }
        let data = try read(
          directory.appendingPathComponent(request.payload!), limit: Self.maximumTextBytes)
        try Self.validateText(data)
        text = data
      }
      // Claim against expiry while the application adopts this document.
      try FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: envelopeURL.path)
      return PendingOpenRequest(request: request, text: text, envelopeURL: envelopeURL)
    }
  }

  public func acknowledge(_ pending: PendingOpenRequest) throws {
    try discard(pending.envelopeURL)
  }

  public func discard(_ envelopeURL: URL) throws {
    try locked {
      guard envelopeURL.deletingLastPathComponent().standardizedFileURL == directory,
        envelopeURL.pathExtension == "ssmvrequest",
        UUID(uuidString: envelopeURL.deletingPathExtension().lastPathComponent) != nil
      else { throw OpenRequestError.invalid }
      try? FileManager.default.removeItem(
        at: envelopeURL.deletingPathExtension().appendingPathExtension("md"))
      if FileManager.default.fileExists(atPath: envelopeURL.path) {
        try FileManager.default.removeItem(at: envelopeURL)
      }
    }
  }

  /// Enumerates pending envelopes without adopting or deleting them. Each must
  /// still pass consume() validation before its content is used.
  public func pendingRequests() throws -> [URL] {
    try locked {
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { url in
          guard url.pathExtension == "ssmvrequest",
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
          else { return false }
          var info = stat()
          return lstat(url.path, &info) == 0 && info.st_uid == getuid()
            && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0
            && info.st_nlink == 1 && info.st_size <= Self.maximumEnvelopeBytes
        }.map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
  }

  public func pruneExpired() throws { try locked { try pruneUnlocked() } }

  private func pruneUnlocked() throws {
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      guard ["ssmvrequest", "md", "partial"].contains(url.pathExtension),
        UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
      else { continue }
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff
      else { continue }
      if url.pathExtension == "md" {
        let envelope = url.deletingPathExtension().appendingPathExtension("ssmvrequest")
        var envelopeInfo = stat()
        if lstat(envelope.path, &envelopeInfo) == 0,
          Date(timeIntervalSince1970: TimeInterval(envelopeInfo.st_mtimespec.tv_sec)) >= cutoff
        {
          continue
        }
      }
      try FileManager.default.removeItem(at: url)
    }
  }
}
