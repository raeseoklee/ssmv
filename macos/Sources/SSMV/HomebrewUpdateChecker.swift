import Foundation

/// Checks the public tap without invoking Homebrew or changing the installation.
@MainActor
final class HomebrewUpdateChecker {
  static let caskURL = URL(
    string: "https://raw.githubusercontent.com/raeseoklee/homebrew-tap/main/Casks/ssmv.rb")!
  static let maximumResponseBytes = 65_536
  private static let lastCheckKey = "homebrewUpdateLastCheck"
  private static let notifiedVersionKey = "homebrewUpdateNotifiedVersion"
  private let defaults: UserDefaults
  private let currentVersion: String
  private let fetch: () async throws -> Data
  private let now: () -> Date

  init(
    currentVersion: String,
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    fetch: @escaping () async throws -> Data = HomebrewUpdateChecker.fetchCask
  ) {
    self.currentVersion = currentVersion
    self.defaults = defaults
    self.now = now
    self.fetch = fetch
  }

  /// Returns a newer, not previously announced version at most once per day.
  /// Call `markNotified` only when the update message is actually presented.
  func check() async -> String? {
    guard Self.components(currentVersion) != nil else { return nil }
    let date = now()
    if let previous = defaults.object(forKey: Self.lastCheckKey) as? Date,
      date.timeIntervalSince(previous) >= 0,
      date.timeIntervalSince(previous) < 24 * 60 * 60
    {
      return nil
    }
    defaults.set(date, forKey: Self.lastCheckKey)
    do {
      let data = try await fetch()
      try Task.checkCancellation()
      guard data.count <= Self.maximumResponseBytes,
        let version = Self.version(in: data),
        Self.isNewer(version, than: currentVersion),
        defaults.string(forKey: Self.notifiedVersionKey) != version
      else { return nil }
      return version
    } catch {
      return nil
    }
  }

  func markNotified(_ version: String) {
    defaults.set(version, forKey: Self.notifiedVersionKey)
  }

  static func version(in data: Data) -> String? {
    guard data.count <= maximumResponseBytes,
      let source = String(data: data, encoding: .utf8),
      let expression = try? NSRegularExpression(
        pattern: #"(?m)^\s*version[ \t]+"([0-9]+\.[0-9]+\.[0-9]+)"[ \t]*$"#)
    else { return nil }
    let matches = expression.matches(
      in: source, range: NSRange(source.startIndex..., in: source))
    guard matches.count == 1,
      let range = Range(matches[0].range(at: 1), in: source)
    else { return nil }
    let version = String(source[range])
    return components(version) == nil ? nil : version
  }

  static func isNewer(_ candidate: String, than installed: String) -> Bool {
    guard let lhs = components(candidate), let rhs = components(installed) else { return false }
    return rhs.lexicographicallyPrecedes(lhs)
  }

  private static func components(_ version: String) -> [UInt64]? {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var result: [UInt64] = []
    for part in parts {
      guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        part.count == 1 || part.first != "0", let number = UInt64(part)
      else { return nil }
      result.append(number)
    }
    return result
  }

  private static func fetchCask() async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: caskURL, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    request.setValue("SSMV-Update-Check", forHTTPHeaderField: "User-Agent")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200, response.url == caskURL,
      response.expectedContentLength <= Int64(maximumResponseBytes)
    else { throw URLError(.badServerResponse) }
    var data = Data()
    for try await byte in bytes {
      guard data.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return data
  }
}
