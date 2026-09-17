import Foundation

public enum DocumentSortOrder: String, CaseIterable {
  case added, name, modified

  public func sorted(
    _ urls: [URL],
    modificationDate: (URL) -> Date? = {
      try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
  ) -> [URL] {
    guard self != .added else { return urls }
    // Read metadata once per file, never from the comparison function.
    let dates = self == .modified ? urls.map(modificationDate) : []
    return urls.enumerated().sorted { left, right in
      if self == .modified {
        let a = dates[left.offset] ?? .distantPast
        let b = dates[right.offset] ?? .distantPast
        if a != b { return a > b }
      } else {
        let order = left.element.lastPathComponent.localizedStandardCompare(
          right.element.lastPathComponent)
        if order != .orderedSame { return order == .orderedAscending }
      }
      return left.offset < right.offset
    }.map(\.element)
  }
}
