import Foundation

/// Immutable source and parsed content from the same file read.
public struct DocumentSnapshot: Sendable {
  public let source: String
  public let document: AttributedString
  public let baseURL: URL?

  public init(source: String, document: AttributedString, baseURL: URL? = nil) {
    self.source = source
    self.document = document
    self.baseURL = baseURL
  }
}

/// Bounds synchronous Foundation parsing while keeping cancellation responsive.
public actor DocumentLoader {
  public static let shared = DocumentLoader()

  private let parser: @Sendable (URL) throws -> DocumentSnapshot
  private enum Work: Sendable {
    case file(URL)
    case text(String, URL?)
  }
  private var pending: [(Work, Request)] = []
  private var active = 0

  public init() {
    parser = { url in
      let source = try MarkdownDocument.read(url, preservingBOM: true)
      let document = try MarkdownDocument.parse(source, baseURL: url.deletingLastPathComponent())
      return DocumentSnapshot(
        source: source, document: document, baseURL: url.deletingLastPathComponent())
    }
  }

  internal init(parser: @escaping @Sendable (URL) throws -> AttributedString) {
    self.parser = { url in
      let document = try parser(url)
      return DocumentSnapshot(source: String(document.characters), document: document)
    }
  }

  public func load(_ url: URL) async throws -> AttributedString {
    try await loadSnapshot(url).document
  }

  public func loadSnapshot(_ url: URL) async throws -> DocumentSnapshot {
    try await enqueue(.file(url))
  }

  public func parseSnapshot(source: String, baseURL: URL?) async throws -> DocumentSnapshot {
    guard source.utf8.count <= MarkdownDocument.maximumBytes else {
      throw MarkdownDocument.ReadError.tooLarge
    }
    return try await enqueue(.text(source, baseURL))
  }

  private func enqueue(_ work: Work) async throws -> DocumentSnapshot {
    try Task.checkCancellation()
    let request = Request()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard request.install(continuation) else { return }
        pending.append((work, request))
        startPending()
      }
    } onCancel: {
      // Resume the caller immediately, even if both Foundation parsers are busy.
      request.finish(.failure(CancellationError()))
      Task { await self.removeCancelled() }
    }
  }

  private func removeCancelled() {
    pending.removeAll { $0.1.isFinished }
  }

  private func startPending() {
    removeCancelled()
    while active < 2 && !pending.isEmpty {
      let (work, request) = pending.removeFirst()
      guard !request.isFinished else { continue }
      active += 1
      let parser = self.parser
      Task.detached(priority: .userInitiated) {
        let result: Result<DocumentSnapshot, Error> = autoreleasepool {
          guard !request.isFinished else { return .failure(CancellationError()) }
          return Result {
            switch work {
            case .file(let url): return try parser(url)
            case .text(let source, let base):
              return DocumentSnapshot(
                source: source, document: try MarkdownDocument.parse(source, baseURL: base),
                baseURL: base)
            }
          }
        }
        await self.completed(request, result: result)
      }
    }
  }

  private func completed(_ request: Request, result: Result<DocumentSnapshot, Error>) {
    active -= 1
    request.finish(result)
    startPending()
  }

  /// Cancellation and parser completion can race; exactly one resumes the caller.
  private final class Request: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DocumentSnapshot, Error>?
    private var finished = false

    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<DocumentSnapshot, Error>) -> Bool {
      let accepted = lock.withLock {
        guard !finished else { return false }
        self.continuation = continuation
        return true
      }
      if !accepted { continuation.resume(throwing: CancellationError()) }
      return accepted
    }

    func finish(_ result: Result<DocumentSnapshot, Error>) {
      let continuation = lock.withLock {
        guard !finished else { return nil as CheckedContinuation<DocumentSnapshot, Error>? }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(with: result)
    }
  }
}
