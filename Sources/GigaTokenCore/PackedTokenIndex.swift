struct PackedTokenIndex {
  private static let empty = UInt32.max

  private var slots: [UInt32]
  private let mask: Int

  init(expectedCount: Int) throws(TokenizerError) {
    let maximumCapacity = 1 << (Int.bitWidth - 2)
    guard expectedCount <= maximumCapacity / 2 else {
      throw TokenizerError.vocabularyTooLarge(count: expectedCount)
    }
    var capacity = 16
    while capacity < expectedCount * 2 {
      capacity *= 2
    }
    slots = [UInt32](repeating: Self.empty, count: capacity)
    mask = capacity - 1
  }

  mutating func insert(
    tokenIndex: UInt32,
    storage: UnsafeBufferPointer<UInt8>,
    offsets: borrowing [UInt32]
  ) -> UInt32? {
    let range = Self.range(tokenIndex: tokenIndex, offsets: offsets)
    var slot = Int(truncatingIfNeeded: Self.hash(storage: storage, range: range)) & mask
    while true {
      let existing = slots[slot]
      if existing == Self.empty {
        slots[slot] = tokenIndex
        return nil
      }
      let existingRange = Self.range(tokenIndex: existing, offsets: offsets)
      if Self.equal(storage: storage, range, existingRange) {
        return existing
      }
      slot = (slot + 1) & mask
    }
  }

  @inline(__always)
  private static func range(
    tokenIndex: UInt32,
    offsets: borrowing [UInt32]
  ) -> Range<Int> {
    let index = Int(tokenIndex)
    return Int(offsets[index])..<Int(offsets[index + 1])
  }

  private static func hash(
    storage: UnsafeBufferPointer<UInt8>,
    range: Range<Int>
  ) -> UInt64 {
    var hash = UInt64(range.count) &* 0x9E37_79B9_7F4A_7C15
    guard !range.isEmpty else {
      return hash
    }
    var position = range.lowerBound
    let baseAddress = storage.baseAddress!
    while position + 8 <= range.upperBound {
      let word = UInt64(
        littleEndian: UnsafeRawPointer(baseAddress.advanced(by: position))
          .loadUnaligned(as: UInt64.self)
      )
      hash ^= word
      hash &*= 0x9E37_79B9_7F4A_7C15
      position += 8
    }
    while position < range.upperBound {
      hash ^= UInt64(baseAddress[position])
      hash &*= 0x100_0000_01B3
      position += 1
    }
    return hash ^ (hash >> 32)
  }

  private static func equal(
    storage: UnsafeBufferPointer<UInt8>,
    _ lhs: Range<Int>,
    _ rhs: Range<Int>
  ) -> Bool {
    guard lhs.count == rhs.count else {
      return false
    }
    guard !lhs.isEmpty else {
      return true
    }
    let baseAddress = storage.baseAddress!
    var offset = 0
    while offset < lhs.count {
      if baseAddress[lhs.lowerBound + offset] != baseAddress[rhs.lowerBound + offset] {
        return false
      }
      offset += 1
    }
    return true
  }
}
