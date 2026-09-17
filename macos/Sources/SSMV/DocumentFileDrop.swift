import AppKit

@MainActor
enum DocumentFileDrop {
  static func urls(from pasteboard: NSPasteboard) -> [URL] {
    (pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter {
        ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased())
          && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
  }

  static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
    let count = urls(from: sender.draggingPasteboard).count
    guard count > 0 else { return [] }
    sender.numberOfValidItemsForDrop = count
    return .copy
  }
}

/// Receives files over the reader, empty space, and other unregistered views.
@MainActor
final class DocumentDropWindow: NSWindow, NSDraggingDestination {
  var onDrop: (([URL]) -> Void)?

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    onDrop == nil ? [] : DocumentFileDrop.operation(for: sender)
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    draggingEntered(sender) == .copy
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let onDrop, DocumentFileDrop.operation(for: sender) == .copy else { return false }
    onDrop(DocumentFileDrop.urls(from: sender.draggingPasteboard))
    return true
  }
}
