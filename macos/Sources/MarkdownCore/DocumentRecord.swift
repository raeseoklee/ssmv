import Foundation

public struct DocumentRecord: Codable, Equatable, Sendable, Identifiable {
  public enum Source: Codable, Equatable, Sendable {
    case localFile(URL)
    case remote(URL)
    case imported(relativePath: String)
  }

  public let id: UUID
  public let source: Source
  public var displayName: String
  public let addedAt: Date
  public let addedOrdinal: Int
  public var sourceModifiedAt: Date?
  public var lastFetchedAt: Date?

  public init(
    id: UUID = UUID(), source: Source, displayName: String, addedAt: Date = Date(),
    addedOrdinal: Int, sourceModifiedAt: Date? = nil, lastFetchedAt: Date? = nil
  ) {
    self.id = id
    self.source = source
    self.displayName = displayName
    self.addedAt = addedAt
    self.addedOrdinal = addedOrdinal
    self.sourceModifiedAt = sourceModifiedAt
    self.lastFetchedAt = lastFetchedAt
  }
}
