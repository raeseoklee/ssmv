import Foundation
import Testing

@testable import MarkdownCore

@Suite @MainActor struct DocumentStoreTests {
  private func fixture() throws -> (UserDefaults, URL) {
    let defaults = UserDefaults(suiteName: "SSMV.StoreTests." + UUID().uuidString)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (defaults, directory)
  }

  @Test func migrationPreservesOrderSelectionAndLegacyData() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var shelf = DocumentShelf()
    let a = URL(fileURLWithPath: "/missing/a.md")
    let b = URL(fileURLWithPath: "/missing/b.md")
    shelf.add([b, a])
    shelf.select(b)
    let legacy = try JSONEncoder().encode(shelf)
    defaults.set(legacy, forKey: "documentShelf")
    let store = try DocumentStore(defaults: defaults, directory: directory)
    #expect(store.records.map(\.source) == [.localFile(b), .localFile(a)])
    #expect(store.selectedRecord?.source == .localFile(b))
    #expect(store.records.map(\.addedOrdinal) == [0, 1])
    #expect(defaults.data(forKey: "documentShelf") == legacy)
    let restored = try DocumentStore(defaults: defaults, directory: directory)
    #expect(restored.records == store.records)
    #expect(restored.selectedID == store.selectedID)
  }

  @Test func importsSurviveRemovalAndRestartAndDuplicateDelivery() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let request = UUID()
    let imported = try store.importText("# Hello\nOriginal body", requestID: request)
    #expect(imported.displayName == "Hello")
    let url = try #require(store.fileURL(for: imported))
    #expect(try String(contentsOf: url, encoding: .utf8) == "# Hello\nOriginal body")
    #expect(throws: DocumentStore.StoreError.self) { try store.deleteUnlistedImport(imported.id) }
    try store.remove(imported.id)
    #expect(store.unlistedImports == [imported])
    #expect(FileManager.default.fileExists(atPath: url.path))
    let restored = try DocumentStore(defaults: defaults, directory: directory)
    #expect(restored.unlistedImports == [imported])
    let duplicate = try restored.importText("# Different body", requestID: request)
    #expect(duplicate == imported)
    #expect(restored.records.count == 1)
    #expect(try String(contentsOf: url, encoding: .utf8) == "# Hello\nOriginal body")
    try restored.removeAllReferences()
    try restored.deleteUnlistedImport(imported.id)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(restored.unlistedImports.isEmpty)
  }

  @Test func quotaAndInvalidImportsKeepExistingDocuments() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(
      defaults: defaults, directory: directory, maximumImportedBytes: 12)
    let first = try store.importText("123456789012", title: "../Very:\n Nice\\name")
    #expect(first.displayName == ".. Very Nice name")
    #expect(store.importedByteCount == 12)
    #expect(throws: DocumentStore.StoreError.self) { try store.importText("x") }
    #expect(throws: DocumentStore.StoreError.self) { try store.importText(" \n\t") }
    #expect(store.records == [first])
    try store.removeAllReferences()
    #expect(throws: DocumentStore.StoreError.self) { try store.importText("x") }
    #expect(store.unlistedImports == [first])
    let attributes = try FileManager.default.attributesOfItem(
      atPath: try #require(store.fileURL(for: first)).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func localAndRemoteDuplicatesKeepStableInsertionOrder() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let first = try store.addLocal([URL(fileURLWithPath: "/tmp/a.md")])[0]
    let remote = try store.addRemote(URL(string: "https://EXAMPLE.com/a.md?token=one#heading")!)
    _ = try store.addLocal([URL(fileURLWithPath: "/tmp/./a.md")])
    let duplicate = try store.addRemote(URL(string: "https://example.com/a.md?token=one#other")!)
    #expect(duplicate.id == remote.id)
    #expect(store.records.map(\.id) == [first.id, remote.id])
    #expect(throws: DocumentStore.StoreError.self) {
      try store.addRemote(URL(string: "https://user@example.com/a.md")!)
    }
    #expect(throws: DocumentStore.StoreError.self) {
      try store.addRemote(URL(string: "http://example.com/a.md")!)
    }
    _ = try store.addRemote(URL(string: "https://example.com/a.md?token=two")!)
    #expect(store.records.count == 3)
  }

  @Test func sourceFileSurvivesAllReferenceRemoval() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let original = directory.appendingPathComponent("original.md")
    try Data("# Keep".utf8).write(to: original)
    _ = try store.addLocal([original])
    try store.removeAllReferences()
    #expect(try String(contentsOf: original, encoding: .utf8) == "# Keep")
  }

  @Test func exactDocumentLimitSucceedsAndOneExtraByteFails() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let text = String(repeating: "a", count: DocumentStore.maximumDocumentBytes)
    let accepted = try store.importText(text)
    #expect(store.importedByteCount == DocumentStore.maximumDocumentBytes)
    #expect(throws: DocumentStore.StoreError.self) { try store.importText(text + "a") }
    #expect(store.records == [accepted])
  }
  @Test func failedPersistenceLeavesMemoryAndPayloadUnchanged() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let index = directory.appendingPathComponent("document-store-v2.json")
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.importText("# Must not be accepted") }
    #expect(store.records.isEmpty)
    #expect(store.importedByteCount == 0)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
        "document-store-v2.json"
      ])
  }

  @Test func corruptIndexNeverSilentlyReplacesTheShelf() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try DocumentStore(defaults: defaults, directory: directory)
    let index = directory.appendingPathComponent("document-store-v2.json")
    try Data("invalid".utf8).write(to: index)
    #expect(throws: (any Error).self) {
      try DocumentStore(defaults: defaults, directory: directory)
    }
    #expect(try String(contentsOf: index, encoding: .utf8) == "invalid")
  }

  @Test func matchingOrphanIsAdoptedAndPersistsAcrossRestart() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString + ".md")
    let body = Data("# Recovered".utf8)
    #expect(
      FileManager.default.createFile(
        atPath: url.path, contents: body, attributes: [.posixPermissions: 0o600]))
    let record = try store.importText("# Recovered", requestID: id)
    #expect(record.id == id)
    #expect(try Data(contentsOf: url) == body)
    let restored = try DocumentStore(defaults: defaults, directory: directory)
    #expect(restored.records == [record])
  }

  @Test func orphanMismatchAndUnsafeFilesAreNeverOverwritten() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString + ".md")
    let original = Data("# Different".utf8)
    #expect(
      FileManager.default.createFile(
        atPath: url.path, contents: original, attributes: [.posixPermissions: 0o600]))
    #expect(throws: DocumentStore.StoreError.self) {
      try store.importText("# Recovered", requestID: id)
    }
    #expect(try Data(contentsOf: url) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(throws: DocumentStore.StoreError.self) {
      try store.importText("# Different", requestID: id)
    }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(
      atPath: url.path, withDestinationPath: directory.appendingPathComponent("missing.md").path)
    #expect(throws: DocumentStore.StoreError.self) {
      try store.importText("# Recovered", requestID: id)
    }
    #expect(store.records.isEmpty)
  }

  @Test func failedOrphanAdoptionKeepsPayloadForRetry() throws {
    let (defaults, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DocumentStore(defaults: defaults, directory: directory)
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString + ".md")
    let body = Data("# Recovered".utf8)
    #expect(
      FileManager.default.createFile(
        atPath: url.path, contents: body, attributes: [.posixPermissions: 0o600]))
    let index = directory.appendingPathComponent("document-store-v2.json")
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.importText("# Recovered", requestID: id) }
    #expect(try Data(contentsOf: url) == body)
    #expect(store.records.isEmpty)
    try FileManager.default.removeItem(at: index)
    let record = try store.importText("# Recovered", requestID: id)
    #expect(store.records == [record])
  }

}
