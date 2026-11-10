import Foundation

/// An organizational sidebar node; its name never becomes a filesystem path.
public struct DocumentCategory: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var name: String
  public var parentID: UUID?

  public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentID = parentID
  }
}
