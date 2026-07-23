struct LongPretokenValue: Sendable {
  let tokenOffset: Int
  let tokenCount: Int

  @inline(__always)
  func appendTokens(
    arena: borrowing [UInt32],
    to output: inout TokenOutputCursor
  ) {
    output.appendTokens(
      arena: arena,
      offset: tokenOffset,
      count: tokenCount
    )
  }
}

private struct LongPretokenCacheEntry: Sendable {
  var hash: UInt64 = 0
  var byteOffset: Int = 0
  var byteCount: Int = 0
  var tokenOffset: Int = 0
  var tokenCount: Int = 0
}

@usableFromInline
struct LongPretokenCache: ~Copyable {
  private var entries: UnsafeMutablePointer<LongPretokenCacheEntry>
  private var capacity: Int
  private var mask: Int
  private var count: Int
  private var byteArena: [UInt8]

  init(minimumCapacity: Int = 64) {
    precondition(MemoryLayout<LongPretokenCacheEntry>.stride == 40)
    var capacity = 16
    while capacity < minimumCapacity {
      capacity <<= 1
    }
    entries = .allocate(capacity: capacity)
    entries.initialize(repeating: LongPretokenCacheEntry(), count: capacity)
    self.capacity = capacity
    mask = capacity - 1
    count = 0
    byteArena = []
  }

  deinit {
    entries.deinitialize(count: capacity)
    entries.deallocate()
  }

  var entryCount: Int {
    count
  }

  var slotCapacity: Int {
    capacity
  }

  var storedByteCount: Int {
    byteArena.count
  }

  @inline(__always)
  func value(
    for bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    hash: UInt64
  ) -> LongPretokenValue? {
    var slot = Int(truncatingIfNeeded: hash) & mask
    while true {
      let entry = entries[slot]
      if entry.byteCount == 0 {
        return nil
      }
      if entry.hash == hash,
        entry.byteCount == range.count,
        equalStoredBytes(entry: entry, bytes: bytes, range: range)
      {
        return LongPretokenValue(
          tokenOffset: entry.tokenOffset,
          tokenCount: entry.tokenCount
        )
      }
      slot = (slot + 1) & mask
    }
  }

  mutating func insert(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    hash: UInt64,
    tokenOffset: Int,
    tokenCount: Int
  ) {
    precondition(range.count > 15)
    if count + 1 > capacity / 2 {
      grow()
    }
    let byteOffset = byteArena.count
    byteArena.append(contentsOf: bytes[range])
    insertEntry(
      LongPretokenCacheEntry(
        hash: hash,
        byteOffset: byteOffset,
        byteCount: range.count,
        tokenOffset: tokenOffset,
        tokenCount: tokenCount
      )
    )
  }

  @inline(__always)
  static func hash(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>
  ) -> UInt64 {
    var hash = UInt64(range.count) &* 0x9E37_79B9_7F4A_7C15
    var position = range.lowerBound
    while position + 8 <= range.upperBound {
      let word = UInt64(
        littleEndian: UnsafeRawPointer(bytes.baseAddress!.advanced(by: position))
          .loadUnaligned(as: UInt64.self)
      )
      hash ^= word
      hash &*= 0x9E37_79B9_7F4A_7C15
      position += 8
    }
    while position < range.upperBound {
      hash ^= UInt64(bytes[position])
      hash &*= 0x100_0000_01B3
      position += 1
    }
    return hash ^ (hash >> 32)
  }

  @inline(__always)
  private func equalStoredBytes(
    entry: LongPretokenCacheEntry,
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>
  ) -> Bool {
    byteArena.withUnsafeBufferPointer { stored in
      var index = 0
      let storedStart = entry.byteOffset
      while index + 8 <= range.count {
        let storedWord = UInt64(
          littleEndian: UnsafeRawPointer(stored.baseAddress!.advanced(by: storedStart + index))
            .loadUnaligned(as: UInt64.self)
        )
        let inputWord = UInt64(
          littleEndian: UnsafeRawPointer(bytes.baseAddress!.advanced(by: range.lowerBound + index))
            .loadUnaligned(as: UInt64.self)
        )
        if storedWord != inputWord {
          return false
        }
        index += 8
      }
      while index < range.count {
        if stored[storedStart + index] != bytes[range.lowerBound + index] {
          return false
        }
        index += 1
      }
      return true
    }
  }

  private mutating func insertEntry(_ entry: LongPretokenCacheEntry) {
    var slot = Int(truncatingIfNeeded: entry.hash) & mask
    while entries[slot].byteCount != 0 {
      slot = (slot + 1) & mask
    }
    entries[slot] = entry
    count += 1
  }

  private mutating func grow() {
    let previousEntries = entries
    let previousCapacity = capacity
    precondition(previousCapacity <= Int.max / 2)
    capacity = previousCapacity * 2
    mask = capacity - 1
    entries = .allocate(capacity: capacity)
    entries.initialize(repeating: LongPretokenCacheEntry(), count: capacity)
    count = 0
    var index = 0
    while index < previousCapacity {
      let entry = previousEntries[index]
      if entry.byteCount != 0 {
        insertEntry(entry)
      }
      index += 1
    }
    previousEntries.deinitialize(count: previousCapacity)
    previousEntries.deallocate()
  }
}
