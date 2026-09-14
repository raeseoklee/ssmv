import AppKit
import Testing

@testable import MarkdownCore

@Test @MainActor func fnLabelPreservesShortcutAndAvoidsDuplicateSuffixes() {
  // AppKit only permits the Fn mask on system-provided items; test its label independently.
  let flags: NSEvent.ModifierFlags = [.control, .function]
  let title = MenuShortcutLabel.title("System Command", key: "c", modifiers: flags)
  #expect(title == "System Command (Fn)")
  #expect(MenuShortcutLabel.title(title, key: "c", modifiers: flags) == title)
  #expect(MenuShortcutLabel.title(title, key: "c", modifiers: .command) == "System Command")
  let menu = NSMenu()
  let copy = menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
  copy.keyEquivalentModifierMask = .command
  MenuShortcutLabel.annotate(menu)
  #expect(copy.title == "Copy")
  #expect(copy.keyEquivalent == "c")
  #expect(copy.keyEquivalentModifierMask == .command)
}
