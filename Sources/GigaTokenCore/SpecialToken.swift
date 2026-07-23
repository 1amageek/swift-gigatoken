public struct SpecialToken: Hashable, Sendable {
  public let bytes: [UInt8]
  public let id: TokenID

  public init(bytes: [UInt8], id: TokenID) {
    self.bytes = bytes
    self.id = id
  }
}

public enum SpecialTokenPolicy: Sendable {
  case disallow
  case allowAll
  case allow([TokenID])

  @inline(__always)
  func allows(_ id: TokenID) -> Bool {
    switch self {
    case .disallow:
      false
    case .allowAll:
      true
    case .allow(let allowed):
      allowed.contains(id)
    }
  }
}
