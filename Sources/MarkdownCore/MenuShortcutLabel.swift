import AppKit

@MainActor
public enum MenuShortcutLabel {
  public static func title(_ title: String, key: String, modifiers: NSEvent.ModifierFlags) -> String
  {
    let suffix = " (Fn)"
    let base = title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : title
    return base + ((!key.isEmpty && modifiers.contains(.function)) ? suffix : "")
  }

  /// Clarify Apple's globe modifier without changing the shortcut itself.
  public static func annotate(_ menu: NSMenu) {
    for item in menu.items {
      item.title = title(
        item.title, key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
      if let submenu = item.submenu { annotate(submenu) }
    }
  }
}
