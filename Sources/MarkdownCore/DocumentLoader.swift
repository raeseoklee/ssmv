import Foundation

/// Bounds synchronous Foundation parsing while keeping cancellation responsive.
public actor DocumentLoader {
  public static let shared = DocumentLoader()

  private let parser: @Sendable (URL) throws -> AttributedString
  private var pending: [(URL, Request)] = []
  private var active = 0

  public init() {
    parser = { url in
      try MarkdownDocument.parse(
        MarkdownDocument.read(url), baseURL: url.deletingLastPathComponent())
    }
  }

  internal init(parser: @escaping @Sendable (URL) throws -> AttributedString) {
    self.parser = parser
  }

  public func load(_ url: URL) async throws -> AttributedString {
    try Task.checkCancellation()
    let request = Request()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard request.install(continuation) else { return }
        pending.append((url, request))
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
      let (url, request) = pending.removeFirst()
      guard !request.isFinished else { continue }
      active += 1
      let parser = self.parser
      Task.detached(priority: .userInitiated) {
        let result: Result<AttributedString, Error> = autoreleasepool {
          guard !request.isFinished else { return .failure(CancellationError()) }
          return Result { try parser(url) }
        }
        await self.completed(request, result: result)
      }
    }
  }

  private func completed(_ request: Request, result: Result<AttributedString, Error>) {
    active -= 1
    request.finish(result)
    startPending()
  }

  /// Cancellation and parser completion can race; exactly one resumes the caller.
  private final class Request: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AttributedString, Error>?
    private var finished = false

    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<AttributedString, Error>) -> Bool {
      let accepted = lock.withLock {
        guard !finished else { return false }
        self.continuation = continuation
        return true
      }
      if !accepted { continuation.resume(throwing: CancellationError()) }
      return accepted
    }

    func finish(_ result: Result<AttributedString, Error>) {
      let continuation = lock.withLock {
        guard !finished else { return nil as CheckedContinuation<AttributedString, Error>? }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(with: result)
    }
  }
}
