public struct TokenBuffer: ~Copyable {
  // This value is the sole owner of `storage`. Exactly one allocation is fully
  // initialized for `capacity` UInt32 values and deallocated in deinit or grow.
  // Mutable borrows exist only inside `withAppender`; its ~Escapable cursor
  // prevents the MutableSpan from surviving a grow, deallocation, or Sendable boundary.
  private var storage: UnsafeMutablePointer<UInt32>?

  public private(set) var count: Int
  public private(set) var capacity: Int

  public init(minimumCapacity: Int = 0) {
    precondition(minimumCapacity >= 0)
    precondition(MemoryLayout<TokenID>.size == MemoryLayout<UInt32>.size)
    precondition(MemoryLayout<TokenID>.stride == MemoryLayout<UInt32>.stride)
    precondition(MemoryLayout<TokenID>.alignment == MemoryLayout<UInt32>.alignment)
    storage =
      minimumCapacity == 0
      ? nil
      : UnsafeMutablePointer<UInt32>.allocate(capacity: minimumCapacity)
    storage?.initialize(
      repeating: 0,
      count: minimumCapacity
    )
    count = 0
    capacity = minimumCapacity
  }

  deinit {
    storage?.deinitialize(count: capacity)
    storage?.deallocate()
  }

  public mutating func reserveCapacity(_ minimumCapacity: Int) {
    precondition(minimumCapacity >= 0)
    guard minimumCapacity > capacity else {
      return
    }
    grow(to: minimumCapacity)
  }

  public mutating func removeAll(keepingCapacity: Bool = true) {
    count = 0
    if !keepingCapacity {
      storage?.deinitialize(count: capacity)
      storage?.deallocate()
      storage = nil
      capacity = 0
    }
  }

  public borrowing func withUnsafeBufferPointer<Result>(
    _ body: (UnsafeBufferPointer<TokenID>) -> Result
  ) -> Result {
    guard let storage else {
      return body(UnsafeBufferPointer(start: nil, count: 0))
    }
    return storage.withMemoryRebound(to: TokenID.self, capacity: capacity) { tokenStorage in
      body(UnsafeBufferPointer(start: tokenStorage, count: count))
    }
  }

  /// Borrows contiguous `UInt32` token IDs without copying.
  ///
  /// The pointer is valid only during `body`. Errors thrown by `body` are
  /// propagated unchanged.
  public borrowing func withUnsafeRawTokenIDs<Result, Failure: Error>(
    _ body: (UnsafeBufferPointer<UInt32>) throws(Failure) -> Result
  ) throws(Failure) -> Result {
    guard let storage else {
      return try body(UnsafeBufferPointer(start: nil, count: 0))
    }
    return try body(UnsafeBufferPointer(start: storage, count: count))
  }

  public borrowing func copyTokens() -> [TokenID] {
    guard let storage else {
      return []
    }
    var tokens: [TokenID] = []
    tokens.reserveCapacity(count)
    var index = 0
    while index < count {
      tokens.append(TokenID(rawValue: storage[index]))
      index += 1
    }
    return tokens
  }

  @inline(__always)
  mutating func withAppender<Result, Failure: Error>(
    maximumAdditionalCount: Int,
    _ body: (inout TokenOutputCursor) throws(Failure) -> Result
  ) throws(Failure) -> Result {
    precondition(maximumAdditionalCount > 0)
    precondition(maximumAdditionalCount <= Int.max - count)
    precondition(maximumAdditionalCount <= Int.max - count - 3)
    // Four-lane inline stores may write up to three initialized guard lanes
    // beyond the logical output. The cursor remains closure-scoped, and the
    // buffer cannot grow or deallocate while its MutableSpan is borrowed.
    let requiredCapacity = count + maximumAdditionalCount + 3
    if requiredCapacity > capacity {
      let doubledCapacity = capacity <= Int.max / 2 ? capacity * 2 : Int.max
      grow(to: max(requiredCapacity, max(16, doubledCapacity)))
    }
    let tail = UnsafeMutableBufferPointer(
      start: storage!.advanced(by: count),
      count: capacity - count
    )
    var cursor = TokenOutputCursor(storage: tail.mutableSpan)
    let result = try body(&cursor)
    precondition(cursor.count <= maximumAdditionalCount)
    count += cursor.count
    return result
  }

  mutating func restoreCount(_ restoredCount: Int) {
    precondition(restoredCount >= 0)
    precondition(restoredCount <= count)
    count = restoredCount
  }

  private mutating func grow(to newCapacity: Int) {
    let newStorage = UnsafeMutablePointer<UInt32>.allocate(capacity: newCapacity)
    newStorage.initialize(
      repeating: 0,
      count: newCapacity
    )
    if let storage {
      UnsafeMutableRawPointer(newStorage).copyMemory(
        from: UnsafeRawPointer(storage),
        byteCount: count * MemoryLayout<UInt32>.stride
      )
      storage.deinitialize(count: capacity)
      storage.deallocate()
    }
    storage = newStorage
    capacity = newCapacity
  }
}

struct TokenOutputCursor: ~Copyable, ~Escapable {
  private var storage: MutableSpan<UInt32>
  private(set) var count: Int = 0

  @_lifetime(copy storage)
  init(storage: consuming MutableSpan<UInt32>) {
    self.storage = storage
  }

  @_transparent
  mutating func appendToken(rawValue: UInt32) {
    precondition(count < storage.count)
    storage[count] = rawValue
    count += 1
  }

  @_transparent
  mutating func appendInlineTokens(value: UInt64, extensionValue: UInt64) {
    let tokenCount = Int(value & 0x7F)
    precondition(tokenCount <= 4)
    precondition(count <= storage.count - tokenCount)
    writeInlineTokens(value: value, extensionValue: extensionValue)
    count += tokenCount
  }

  @_transparent
  mutating func writeInlineTokens(value: UInt64, extensionValue: UInt64) {
    writeInlineTokens(value: value, extensionValue: extensionValue, at: count)
  }

  @_transparent
  mutating func writeInlineTokens(
    value: UInt64,
    extensionValue: UInt64,
    at outputOffset: Int
  ) {
    precondition(outputOffset >= 0)
    precondition(outputOffset <= storage.count - 4)
    let firstPair = ((value >> 8) & 0x00FF_FFFF) | (value & 0xFFFF_FFFF_0000_0000)
    let lanes = SIMD2(firstPair, extensionValue)
    storage.withUnsafeMutableBufferPointer { destination in
      withUnsafeBytes(of: lanes) { bytes in
        UnsafeMutableRawPointer(destination.baseAddress!.advanced(by: outputOffset)).copyMemory(
          from: bytes.baseAddress!,
          byteCount: MemoryLayout<SIMD2<UInt64>>.size
        )
      }
    }
  }

  @_transparent
  @unsafe
  mutating func writeUncheckedInlineTokenGroup(
    values: SIMD4<UInt64>,
    extensionValues: SIMD4<UInt64>,
    at outputOffset: Int
  ) -> Int {
    // The caller proves that all four values are inline packed tokens, every
    // offset sum fits in Int, and three initialized guard lanes may follow the
    // logical output. TokenBuffer exclusively owns initialized UInt32 storage;
    // MutableSpan keeps this borrow exclusive, each raw pointer stays inside
    // its synchronous closure, and no pointer or view crosses a Sendable boundary.
    let firstCount = Int(values[0] & 0x7F)
    let secondCount = Int(values[1] & 0x7F)
    let thirdCount = Int(values[2] & 0x7F)
    let fourthCount = Int(values[3] & 0x7F)
    let secondOffset = outputOffset &+ firstCount
    let thirdOffset = secondOffset &+ secondCount
    let fourthOffset = thirdOffset &+ thirdCount
    let endOffset = fourthOffset &+ fourthCount
    assert(outputOffset >= 0)
    assert((1...4).contains(firstCount))
    assert((1...4).contains(secondCount))
    assert((1...4).contains(thirdCount))
    assert((1...4).contains(fourthCount))
    assert(fourthOffset <= storage.count - 4)
    assert(endOffset <= storage.count)

    let firstPair =
      ((values[0] >> 8) & 0x00FF_FFFF) | (values[0] & 0xFFFF_FFFF_0000_0000)
    let secondPair =
      ((values[1] >> 8) & 0x00FF_FFFF) | (values[1] & 0xFFFF_FFFF_0000_0000)
    let thirdPair =
      ((values[2] >> 8) & 0x00FF_FFFF) | (values[2] & 0xFFFF_FFFF_0000_0000)
    let fourthPair =
      ((values[3] >> 8) & 0x00FF_FFFF) | (values[3] & 0xFFFF_FFFF_0000_0000)
    let firstLanes = SIMD2(firstPair, extensionValues[0])
    let secondLanes = SIMD2(secondPair, extensionValues[1])
    let thirdLanes = SIMD2(thirdPair, extensionValues[2])
    let fourthLanes = SIMD2(fourthPair, extensionValues[3])

    storage.withUnsafeMutableBufferPointer { destination in
      let baseAddress = destination.baseAddress!
      withUnsafeBytes(of: firstLanes) { bytes in
        UnsafeMutableRawPointer(baseAddress.advanced(by: outputOffset)).copyMemory(
          from: bytes.baseAddress!,
          byteCount: MemoryLayout<SIMD2<UInt64>>.size
        )
      }
      withUnsafeBytes(of: secondLanes) { bytes in
        UnsafeMutableRawPointer(baseAddress.advanced(by: secondOffset)).copyMemory(
          from: bytes.baseAddress!,
          byteCount: MemoryLayout<SIMD2<UInt64>>.size
        )
      }
      withUnsafeBytes(of: thirdLanes) { bytes in
        UnsafeMutableRawPointer(baseAddress.advanced(by: thirdOffset)).copyMemory(
          from: bytes.baseAddress!,
          byteCount: MemoryLayout<SIMD2<UInt64>>.size
        )
      }
      withUnsafeBytes(of: fourthLanes) { bytes in
        UnsafeMutableRawPointer(baseAddress.advanced(by: fourthOffset)).copyMemory(
          from: bytes.baseAddress!,
          byteCount: MemoryLayout<SIMD2<UInt64>>.size
        )
      }
    }
    return endOffset
  }

  @_transparent
  mutating func advance(by additionalCount: Int) {
    precondition(additionalCount >= 0)
    precondition(count <= storage.count - additionalCount)
    count += additionalCount
  }

  @inline(__always)
  mutating func appendTokens(
    arena: borrowing [UInt32],
    offset: Int,
    count tokenCount: Int
  ) {
    precondition(offset >= 0)
    precondition(tokenCount >= 0)
    precondition(offset <= arena.count - tokenCount)
    precondition(count <= storage.count - tokenCount)
    storage.withUnsafeMutableBufferPointer { destination in
      arena.withUnsafeBufferPointer { tokens in
        UnsafeMutableRawPointer(destination.baseAddress!.advanced(by: count)).copyMemory(
          from: UnsafeRawPointer(tokens.baseAddress!.advanced(by: offset)),
          byteCount: tokenCount * MemoryLayout<UInt32>.stride
        )
      }
    }
    count += tokenCount
  }

}
