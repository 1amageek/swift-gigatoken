import VectorKernels
import VectorKernelsNative

struct PackedTokenValue: Sendable {
  private static let spillFlag: UInt64 = 0x80

  let value: UInt64
  let extensionValue: UInt64

  @inline(__always)
  var tokenCount: Int {
    Int(value & 0x7F)
  }

  @inline(__always)
  static func pack(
    symbols: borrowing InlineArray<16, UInt32>,
    count: Int,
    arena: inout [UInt32]
  ) -> Self {
    let first = symbols[0]
    if count <= 4, first < (1 << 24) {
      var value = UInt64(count) | (UInt64(first) << 8)
      var extensionValue: UInt64 = 0
      if count >= 2 {
        value |= UInt64(symbols[1]) << 32
      }
      if count >= 3 {
        extensionValue = UInt64(symbols[2])
      }
      if count == 4 {
        extensionValue |= UInt64(symbols[3]) << 32
      }
      return Self(value: value, extensionValue: extensionValue)
    }

    let offset = arena.count
    var index = 0
    while index < count {
      arena.append(symbols[index])
      index += 1
    }
    return Self(
      value: spillFlag | UInt64(count) | (UInt64(offset) << 8),
      extensionValue: 0
    )
  }

  @inline(__always)
  func appendTokens(
    arena: borrowing [UInt32],
    to output: inout TokenOutputCursor
  ) {
    let count = Int(value & 0x7F)
    if value & Self.spillFlag != 0 {
      let offset = Int(value >> 8)
      output.appendTokens(arena: arena, offset: offset, count: count)
      return
    }
    output.appendInlineTokens(value: value, extensionValue: extensionValue)
  }
}

private struct ShortPretokenCacheBucket: ~Copyable {
  var keys = SIMD4<UInt64>(repeating: 0)
  var packedValues = SIMD4<UInt64>(repeating: 0)
}

@usableFromInline
struct ShortPretokenCache: ~Copyable {
  // This cache exclusively owns one raw allocation bound to `capacity / 2`
  // initialized buckets. Probe and prefetch pointers are derived and consumed
  // within each call; none escape across grow, exactly-once deallocation, or mutation.
  private var allocation: UnsafeMutableRawPointer
  private var buckets: UnsafeMutablePointer<ShortPretokenCacheBucket>
  private var capacity: Int
  private var mask: Int
  private var count: Int

  init(expectedCount: Int) {
    precondition(MemoryLayout<ShortPretokenCacheBucket>.stride == 64)
    precondition(expectedCount >= 0)
    var capacity = 64
    while Self.shouldGrow(entryCount: expectedCount, capacity: capacity) {
      precondition(capacity <= Int.max / 2)
      capacity <<= 1
    }
    let storage = Self.allocate(capacity: capacity)
    allocation = storage.allocation
    buckets = storage.buckets
    self.capacity = capacity
    mask = capacity - 1
    count = 0
  }

  deinit {
    buckets.deinitialize(count: capacity / 2)
    allocation.deallocate()
  }

  var entryCount: Int {
    count
  }

  var slotCapacity: Int {
    capacity
  }

  var addressModulo64: Int {
    Int(bitPattern: allocation) & 63
  }

  var addressModuloTwoMiB: Int {
    Int(bitPattern: allocation) & ((2 * 1024 * 1024) - 1)
  }

  @inline(__always)
  func value(for key: ShortPretokenKey) -> PackedTokenValue? {
    value(for: key, hash: key.hash)
  }

  @inline(__always)
  func value(for key: ShortPretokenKey, hash: UInt64) -> PackedTokenValue? {
    let slot = Int(truncatingIfNeeded: hash) & mask & ~1
    return value(for: key, startingAt: slot)
  }

  @inline(__always)
  func valueAfterHomePair(for key: ShortPretokenKey, hash: UInt64) -> PackedTokenValue? {
    let homeSlot = Int(truncatingIfNeeded: hash) & mask & ~1
    return value(for: key, startingAt: (homeSlot + 2) & mask)
  }

  @inline(__always)
  private func value(
    for key: ShortPretokenKey,
    startingAt startSlot: Int
  ) -> PackedTokenValue? {
    var slot = startSlot
    while true {
      let bucket = buckets.advanced(by: slot >> 1)
      let firstKeyLow = bucket.pointee.keys[0]
      let firstKeyHigh = bucket.pointee.keys[1]
      if firstKeyLow == key.low, firstKeyHigh == key.high {
        return PackedTokenValue(
          value: loadValue(from: bucket.pointee, at: 0),
          extensionValue: loadValue(from: bucket.pointee, at: 1)
        )
      }
      let secondKeyLow = bucket.pointee.keys[2]
      let secondKeyHigh = bucket.pointee.keys[3]
      if secondKeyLow == key.low, secondKeyHigh == key.high {
        return PackedTokenValue(
          value: loadValue(from: bucket.pointee, at: 2),
          extensionValue: loadValue(from: bucket.pointee, at: 3)
        )
      }
      if firstKeyHigh == 0 || secondKeyHigh == 0 {
        return nil
      }
      slot = (slot + 2) & mask
    }
  }

  @inline(__always)
  func prefetchForRead(
    hash: UInt64,
    locality: CachePrefetchLocality
  ) {
    let bucketIndex = (Int(truncatingIfNeeded: hash) >> 1) & (mask >> 1)
    unsafe CacheLinePrefetch.read(
      UnsafeRawPointer(buckets.advanced(by: bucketIndex)),
      locality: locality
    )
  }

  @inline(__always)
  func probePair(
    low: UInt64,
    high: UInt64,
    hash: UInt64
  ) -> ShortPretokenProbeResult {
    let bucketIndex = (Int(truncatingIfNeeded: hash) >> 1) & (mask >> 1)
    let bucket = buckets.advanced(by: bucketIndex)
    let keys = bucket.pointee.keys
    let firstMask = Self.zeroMask((keys[0] ^ low) | (keys[1] ^ high))
    let secondMask = Self.zeroMask((keys[2] ^ low) | (keys[3] ^ high))
    let packedValues = bucket.pointee.packedValues
    let selectedValue =
      (packedValues[0] & firstMask) | (packedValues[2] & ~firstMask)
    let selectedExtension =
      (packedValues[1] & firstMask) | (packedValues[3] & ~firstMask)
    return ShortPretokenProbeResult(
      value: PackedTokenValue(
        value: selectedValue,
        extensionValue: selectedExtension
      ),
      foundMask: firstMask | secondMask
    )
  }

  @_transparent
  static func zeroMask(_ value: UInt64) -> UInt64 {
    let isNonzero = (value | (UInt64(0) &- value)) &>> 63
    return UInt64(0) &- (isNonzero ^ 1)
  }

  mutating func insert(
    _ value: PackedTokenValue,
    for key: ShortPretokenKey
  ) {
    if Self.shouldGrow(entryCount: count + 1, capacity: capacity) {
      grow()
    }
    insertWithoutGrowing(value, for: key)
  }

  private mutating func insertWithoutGrowing(
    _ value: PackedTokenValue,
    for key: ShortPretokenKey
  ) {
    var slot = Int(truncatingIfNeeded: key.hash) & mask & ~1
    while true {
      let bucketIndex = slot >> 1
      let bucket = buckets.advanced(by: bucketIndex)
      if bucket.pointee.keys[1] == 0 {
        bucket.pointee.keys[0] = key.low
        bucket.pointee.keys[1] = key.high
        storeValue(value.value, in: bucket, at: 0)
        storeValue(value.extensionValue, in: bucket, at: 1)
        count += 1
        return
      }
      if bucket.pointee.keys[3] == 0 {
        bucket.pointee.keys[2] = key.low
        bucket.pointee.keys[3] = key.high
        storeValue(value.value, in: bucket, at: 2)
        storeValue(value.extensionValue, in: bucket, at: 3)
        count += 1
        return
      }
      if bucket.pointee.keys[0] == key.low, bucket.pointee.keys[1] == key.high {
        storeValue(value.value, in: bucket, at: 0)
        storeValue(value.extensionValue, in: bucket, at: 1)
        return
      }
      if bucket.pointee.keys[2] == key.low, bucket.pointee.keys[3] == key.high {
        storeValue(value.value, in: bucket, at: 2)
        storeValue(value.extensionValue, in: bucket, at: 3)
        return
      }
      slot = (slot + 2) & mask
    }
  }

  private mutating func grow() {
    let previousAllocation = allocation
    let previousBuckets = buckets
    let previousCapacity = capacity
    precondition(previousCapacity <= Int.max / 2)
    let newCapacity = previousCapacity * 2
    let storage = Self.allocate(capacity: newCapacity)
    allocation = storage.allocation
    buckets = storage.buckets
    capacity = newCapacity
    mask = newCapacity - 1
    count = 0
    var bucketIndex = 0
    while bucketIndex < previousCapacity / 2 {
      let bucket = previousBuckets.advanced(by: bucketIndex)
      if bucket.pointee.keys[1] != 0 {
        insertWithoutGrowing(
          PackedTokenValue(
            value: loadValue(from: bucket.pointee, at: 0),
            extensionValue: loadValue(from: bucket.pointee, at: 1)
          ),
          for: ShortPretokenKey(low: bucket.pointee.keys[0], high: bucket.pointee.keys[1])
        )
      }
      if bucket.pointee.keys[3] != 0 {
        insertWithoutGrowing(
          PackedTokenValue(
            value: loadValue(from: bucket.pointee, at: 2),
            extensionValue: loadValue(from: bucket.pointee, at: 3)
          ),
          for: ShortPretokenKey(low: bucket.pointee.keys[2], high: bucket.pointee.keys[3])
        )
      }
      bucketIndex += 1
    }
    previousBuckets.deinitialize(count: previousCapacity / 2)
    previousAllocation.deallocate()
  }

  @inline(__always)
  private static func shouldGrow(entryCount: Int, capacity: Int) -> Bool {
    #if arch(arm64) && canImport(Darwin) && !hasFeature(Embedded)
      entryCount > capacity / 4
    #else
      entryCount > capacity - capacity / 4
    #endif
  }

  private static func allocate(
    capacity: Int
  ) -> (
    allocation: UnsafeMutableRawPointer,
    buckets: UnsafeMutablePointer<ShortPretokenCacheBucket>
  ) {
    precondition(capacity / 2 <= Int.max / MemoryLayout<ShortPretokenCacheBucket>.stride)
    let bucketCount = capacity / 2
    let byteCount = bucketCount * MemoryLayout<ShortPretokenCacheBucket>.stride
    #if arch(wasm32)
      let alignment = 64
    #else
      let alignment = min(2 * 1024 * 1024, byteCount)
    #endif
    let allocation = UnsafeMutableRawPointer.allocate(
      byteCount: byteCount,
      alignment: alignment
    )
    let buckets = allocation.bindMemory(
      to: ShortPretokenCacheBucket.self,
      capacity: bucketCount
    )
    var bucketIndex = 0
    while bucketIndex < bucketCount {
      buckets.advanced(by: bucketIndex).initialize(to: ShortPretokenCacheBucket())
      bucketIndex += 1
    }
    return (allocation, buckets)
  }

  @inline(__always)
  private func loadValue(
    from bucket: borrowing ShortPretokenCacheBucket,
    at index: Int
  ) -> UInt64 {
    bucket.packedValues[index]
  }

  @inline(__always)
  private func storeValue(
    _ value: UInt64,
    in bucket: UnsafeMutablePointer<ShortPretokenCacheBucket>,
    at index: Int
  ) {
    bucket.pointee.packedValues[index] = value
  }
}

struct ShortPretokenProbeResult {
  let value: PackedTokenValue
  let foundMask: UInt64
}
