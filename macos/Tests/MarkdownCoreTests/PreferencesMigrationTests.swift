import Foundation
import Testing

@testable import MarkdownCore

@Test func migrationPreservesExistingSettingsAndDoesNotRepeat() throws {
  let name = "SSMVTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(1, forKey: "appearance")
  let shelf = Data("saved documents".utf8)
  PreferencesMigration.migrate(
    defaults: defaults,
    legacyDomain: [
      "appearance": 2, "documentShelf": shelf, "sidebarCollapsed": true, "unrelated": "ignore",
    ])
  #expect(defaults.integer(forKey: "appearance") == 1)
  #expect(defaults.data(forKey: "documentShelf") == shelf)
  #expect(defaults.bool(forKey: "sidebarCollapsed"))
  #expect(defaults.object(forKey: "unrelated") == nil)
  defaults.removeObject(forKey: "documentShelf")
  PreferencesMigration.migrate(defaults: defaults, legacyDomain: ["documentShelf": shelf])
  #expect(defaults.object(forKey: "documentShelf") == nil)
}
