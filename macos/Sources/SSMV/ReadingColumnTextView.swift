import AppKit

/// Keep a comfortable reading measure while allowing the scroll view to fill the window.
@MainActor
final class ReadingColumnTextView: NSTextView {
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let margin = max(24, floor((newSize.width - 760) / 2))
    if textContainerInset.width != margin || textContainerInset.height != 32 {
      textContainerInset = NSSize(width: margin, height: 32)
    }
  }
}
