public struct TokenBuffer: ~Copyable {
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

  mutating func makeAppender(maximumAdditionalCount: Int) -> TokenOutputCursor {
    precondition(maximumAdditionalCount > 0)
    precondition(maximumAdditionalCount <= Int.max - count)
    let requiredCapacity = count + maximumAdditionalCount
    if requiredCapacity > capacity {
      let doubledCapacity = capacity <= Int.max / 2 ? capacity * 2 : Int.max
      grow(to: max(requiredCapacity, max(16, doubledCapacity)))
    }
    return TokenOutputCursor(storage: storage!.advanced(by: count))
  }

  mutating func commitAppender(count appendedCount: Int) {
    precondition(appendedCount >= 0)
    precondition(count + appendedCount <= capacity)
    count += appendedCount
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

struct TokenOutputCursor: ~Copyable {
  let storage: UnsafeMutablePointer<UInt32>
  private(set) var count: Int = 0

  @_transparent
  mutating func appendToken(rawValue: UInt32) {
    storage.advanced(by: count).pointee = rawValue
    count &+= 1
  }

  @_transparent
  mutating func appendInlineTokens(value: UInt64, extensionValue: UInt64) {
    writeInlineTokens(value: value, extensionValue: extensionValue)
    count &+= Int(value & 0x7F)
  }

  @_transparent
  mutating func writeInlineTokens(value: UInt64, extensionValue: UInt64) {
    writeInlineTokens(value: value, extensionValue: extensionValue, at: count)
  }

  @_transparent
  borrowing func writeInlineTokens(
    value: UInt64,
    extensionValue: UInt64,
    at outputOffset: Int
  ) {
    let destination = storage.advanced(by: outputOffset)
    let firstPair = ((value >> 8) & 0x00FF_FFFF) | (value & 0xFFFF_FFFF_0000_0000)
    let lanes = SIMD2(firstPair, extensionValue)
    withUnsafeBytes(of: lanes) { bytes in
      UnsafeMutableRawPointer(destination).copyMemory(
        from: bytes.baseAddress!,
        byteCount: MemoryLayout<SIMD2<UInt64>>.size
      )
    }
  }

  @_transparent
  mutating func advance(by additionalCount: Int) {
    count &+= additionalCount
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
    arena.withUnsafeBufferPointer { tokens in
      UnsafeMutableRawPointer(storage.advanced(by: count)).copyMemory(
        from: UnsafeRawPointer(tokens.baseAddress!.advanced(by: offset)),
        byteCount: tokenCount * MemoryLayout<UInt32>.stride
      )
    }
    count &+= tokenCount
  }

}
