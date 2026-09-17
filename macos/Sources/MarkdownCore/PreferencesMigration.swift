import Foundation

public enum PreferencesMigration {
  /// Copy only our own settings, once, without changing the previous app's preferences.
  public static func migrate(defaults: UserDefaults, legacyDomain: [String: Any]) {
    let marker = "legacyPreferencesMigrated"
    guard !defaults.bool(forKey: marker) else { return }
    for key in ["documentShelf", "appearance", "sidebarCollapsed", "NSWindow Frame ReaderWindow"]
    where defaults.object(forKey: key) == nil {
      if let value = legacyDomain[key] { defaults.set(value, forKey: key) }
    }
    defaults.set(true, forKey: marker)
  }
}
