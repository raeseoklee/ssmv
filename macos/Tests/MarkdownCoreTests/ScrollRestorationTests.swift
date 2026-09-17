import Foundation
import Testing

@testable import MarkdownCore

@Test func repeatedRenderingPreservesPendingReadingPosition() {
  var restoration = ScrollRestoration()
  let saved = CGPoint(x: 0, y: 4_000)
  restoration.begin(at: saved, current: .zero)
  // The first batch starts at the top; another zoom must retain the destination.
  restoration.begin(current: .zero)
  #expect(restoration.target == saved)
  #expect(restoration.positionToSave(current: .zero) == saved)
  restoration.clear()
  restoration.begin(current: CGPoint(x: 0, y: 200))
  #expect(restoration.target?.y == 200)
}

@Test func userScrollingAndNewDocumentReplacePendingRestoration() {
  var restoration = ScrollRestoration()
  restoration.begin(at: CGPoint(x: 0, y: 4_000), current: .zero)
  restoration.clear()
  #expect(restoration.positionToSave(current: .zero) == .zero)
  restoration.begin(at: CGPoint(x: 0, y: 800), current: .zero)
  restoration.begin(at: .zero, current: CGPoint(x: 0, y: 100))
  #expect(restoration.target == .zero)
}

@Test func keyboardNavigationReplacesPendingReadingPosition() {
  var restoration = ScrollRestoration()
  restoration.begin(at: CGPoint(x: 0, y: 4_000), current: .zero)
  let navigated = CGPoint(x: 0, y: 600)
  #expect(restoration.positionToSave(current: navigated) == navigated)
  restoration.begin(current: navigated)
  #expect(restoration.target == navigated)
}
