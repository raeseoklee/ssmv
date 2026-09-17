import Foundation

/// Keeps the intended reading location while a replacement render is incomplete.
public struct ScrollRestoration {
  public private(set) var target: CGPoint?

  public init() {}

  public mutating func begin(at requested: CGPoint? = nil, current: CGPoint) {
    target = requested ?? (current != .zero ? current : target) ?? current
  }

  public func positionToSave(current: CGPoint) -> CGPoint {
    current != .zero ? current : target ?? current
  }

  public mutating func clear() { target = nil }
}
