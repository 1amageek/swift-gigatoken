struct PairRankTable: Sendable {
  private static let emptyKey = UInt64.max

  private var keys: [UInt64]
  private var values: [UInt32]
  private let mask: Int

  init(expectedCount: Int) throws(TokenizerError) {
    let maximumCapacity = 1 << (Int.bitWidth - 2)
    guard expectedCount <= maximumCapacity / 2 else {
      throw TokenizerError.vocabularyTooLarge(count: expectedCount)
    }
    let requested = max(16, expectedCount * 2)
    var capacity = 1
    while capacity < requested {
      capacity <<= 1
    }
    keys = [UInt64](repeating: Self.emptyKey, count: capacity)
    values = [UInt32](repeating: UInt32.max, count: capacity)
    mask = capacity - 1
  }

  @inline(__always)
  func mergedTokenRaw(left: UInt32, right: UInt32) -> UInt32 {
    let key = Self.key(left: left, right: right)
    var slot = Int(truncatingIfNeeded: Self.hash(key)) & mask
    while true {
      let existing = keys[slot]
      if existing == key {
        return values[slot]
      }
      if existing == Self.emptyKey {
        return UInt32.max
      }
      slot = (slot + 1) & mask
    }
  }

  mutating func insert(
    left: TokenID,
    right: TokenID,
    merged: TokenID
  ) throws(TokenizerError) {
    let key = Self.key(left: left.rawValue, right: right.rawValue)
    var slot = Int(truncatingIfNeeded: Self.hash(key)) & mask
    while true {
      let existing = keys[slot]
      if existing == Self.emptyKey {
        keys[slot] = key
        values[slot] = merged.rawValue
        return
      }
      if existing == key {
        throw TokenizerError.duplicateMerge(left: left, right: right)
      }
      slot = (slot + 1) & mask
    }
  }

  @inline(__always)
  private static func key(left: UInt32, right: UInt32) -> UInt64 {
    (UInt64(left) << 32) | UInt64(right)
  }

  @inline(__always)
  private static func hash(_ key: UInt64) -> UInt64 {
    var value = key &* 0x9E37_79B9_7F4A_7C15
    value ^= value >> 30
    value &*= 0xBF58_476D_1CE4_E5B9
    value ^= value >> 27
    return value ^ (value >> 31)
  }
}
