import Foundation

/// Keeps file references only; inactive document contents are not held in memory.
public struct DocumentShelf: Codable, Equatable {
  public private(set) var urls: [URL] = []
  public private(set) var selectedURL: URL?

  public init() {}

  public mutating func add(_ additions: [URL]) {
    for url in additions {
      let canonical = url.standardizedFileURL
      if !urls.contains(canonical) { urls.append(canonical) }
      selectedURL = canonical
    }
  }

  public mutating func select(_ url: URL) {
    if urls.contains(url) { selectedURL = url }
  }

  public mutating func removeSelected() {
    guard let selectedURL, let index = urls.firstIndex(of: selectedURL) else { return }
    urls.remove(at: index)
    self.selectedURL = urls.isEmpty ? nil : urls[min(index, urls.count - 1)]
  }
}
