import Foundation
import Testing

@testable import MarkdownCore

@Suite @MainActor struct DocumentCategoryTests {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults = UserDefaults(suiteName: "SSMV.CategoryTests." + UUID().uuidString)!

  @Test func removingACategoryPromotesItsContentsWithoutMovingFilesOrResettingSelection() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let original = directory.appendingPathComponent("guide.md")
    try Data("original".utf8).write(to: original)
    let local = try #require(store.addLocal([original]).first)
    let imported = try store.importText("imported")
    let importedURL = try #require(store.fileURL(for: imported))
    let root = try store.createCategory(name: "Engineering")
    let parent = try store.createCategory(name: " Architecture ", parentID: root)
    let child = try store.createCategory(name: "Diagrams", parentID: parent)
    try store.moveDocument(local.id, to: parent)
    try store.moveDocument(imported.id, to: child)
    try store.renameCategory(child, name: "Diagrams / architecture")
    try store.removeCategory(parent)
    let restored = try DocumentStore(defaults: defaults, directory: directory)
    #expect(restored.categories.map(\.id) == [root, child])
    #expect(restored.categories.last?.parentID == root)
    #expect(restored.categories.last?.name == "Diagrams / architecture")
    #expect(restored.categoryID(for: local.id) == root)
    #expect(restored.categoryID(for: imported.id) == child)
    #expect(restored.records == [local, imported])
    #expect(restored.selectedID == imported.id)
    try restored.removeCategory(root)
    #expect(restored.categoryID(for: local.id) == nil)
    #expect(restored.categories.first?.parentID == nil)
    try restored.removeAllReferences()
    #expect(restored.categories.map(\.id) == [child])
    #expect(restored.categoryID(for: imported.id) == nil)
    #expect(try Data(contentsOf: original) == Data("original".utf8))
    #expect(try Data(contentsOf: importedURL) == Data("imported".utf8))
  }

  @Test func existingShelfWithoutCategoryFieldsRemainsAtRoot() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let local = try #require(store.addLocal([directory.appendingPathComponent("old.md")]).first)
    let index = directory.appendingPathComponent("document-store-v2.json")
    let data = try Data(contentsOf: index)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["categories"] == nil && json["membership"] == nil)
    let restored = try DocumentStore(defaults: defaults, directory: directory)
    #expect(restored.categories.isEmpty && restored.categoryID(for: local.id) == nil)
    #expect(restored.selectedID == local.id)
    let category = try restored.createCategory(name: "Work")
    try restored.moveDocument(local.id, to: category)
    try restored.remove(local.id)
    #expect(restored.categoryID(for: local.id) == nil)
  }

  @Test func rejectsMissingTargetsInvalidNamesAndStoredCycles() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let root = try store.createCategory(name: "Work")
    #expect(throws: DocumentStore.StoreError.self) { try store.createCategory(name: " \n ") }
    #expect(throws: DocumentStore.StoreError.self) {
      try store.renameCategory(root, name: "bad\nname")
    }
    #expect(throws: DocumentStore.StoreError.self) {
      try store.createCategory(name: "Child", parentID: UUID())
    }
    let record = try store.importText("notes")
    #expect(throws: DocumentStore.StoreError.self) { try store.moveDocument(record.id, to: UUID()) }
    #expect(throws: DocumentStore.StoreError.self) { try store.moveDocument(UUID(), to: root) }
    #expect(store.categoryID(for: record.id) == nil)
    let index = directory.appendingPathComponent("document-store-v2.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
    json["categories"] = [["id": root.uuidString, "name": "Work", "parentID": root.uuidString]]
    try JSONSerialization.data(withJSONObject: json).write(to: index)
    #expect(throws: DocumentStore.StoreError.self) {
      try DocumentStore(defaults: defaults, directory: directory)
    }
  }
}
