import VectorKernels

/// A byte-level tokenizer with borrowed-input and caller-owned-output entry points.
///
/// Every appending operation is atomic: when it throws, the output retains its
/// original count and contents.
public protocol TokenEncoding: ~Copyable {
  mutating func encodeOrdinary(_ bytes: [UInt8]) throws(TokenizerError) -> [TokenID]
  mutating func encodeOrdinary(
    _ bytes: [UInt8],
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError)
  mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError)
  mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError)
  mutating func encode(
    _ bytes: [UInt8],
    specialTokenPolicy: SpecialTokenPolicy
  ) throws(TokenizerError) -> [TokenID]
  mutating func encode(
    _ bytes: UnsafeBufferPointer<UInt8>,
    specialTokenPolicy: SpecialTokenPolicy,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError)
}

public struct BPEEncoder: ~Copyable, TokenEncoding {
  public let model: BPEModel

  private let pretokenizer: R50KPretokenizer
  private var shortCache: ShortPretokenCache
  private var longCache: LongPretokenCache
  private var tokenArena: [UInt32]
  private var mergeWorkspace: BPEMergeWorkspace
  private var pretokenScratch: PretokenScratchStorage

  public init(model: BPEModel) {
    self.model = model
    pretokenizer = R50KPretokenizer()
    shortCache = ShortPretokenCache(expectedCount: model.shortTokenCount)
    longCache = LongPretokenCache()
    tokenArena = []
    mergeWorkspace = BPEMergeWorkspace()
    pretokenScratch = PretokenScratchStorage()
    seedShortCache()
  }

  deinit {}

  public var storageMetrics: EncodingStorageMetrics {
    EncodingStorageMetrics(
      shortCacheEntryCount: shortCache.entryCount,
      shortCacheSlotCapacity: shortCache.slotCapacity,
      shortCacheAddressModulo64: shortCache.addressModulo64,
      shortCacheAddressModuloTwoMiB: shortCache.addressModuloTwoMiB,
      longCacheEntryCount: longCache.entryCount,
      longCacheSlotCapacity: longCache.slotCapacity,
      longCacheStoredByteCount: longCache.storedByteCount,
      tokenArenaCount: tokenArena.count,
      tokenArenaCapacity: tokenArena.capacity,
      mergeSymbolCount: mergeWorkspace.symbolCount,
      mergeSymbolCapacity: mergeWorkspace.symbolCapacity,
      mergeLinkCapacity: mergeWorkspace.linkCapacity
    )
  }

  public mutating func encodeOrdinary(_ bytes: [UInt8]) throws(TokenizerError) -> [TokenID] {
    var output = TokenBuffer(minimumCapacity: max(1, bytes.count / 3))
    try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try encodeOrdinary(buffer, appendingTo: &output)
    }
    return output.copyTokens()
  }

  public mutating func encodeOrdinary(
    _ bytes: [UInt8],
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError) {
    var encoded = TokenBuffer(minimumCapacity: max(1, bytes.count / 3))
    try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try encodeOrdinary(buffer, appendingTo: &encoded)
    }
    encoded.withUnsafeBufferPointer { tokens in
      output.append(contentsOf: tokens)
    }
  }

  public mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError) {
    var encoded = TokenBuffer(minimumCapacity: max(1, bytes.count / 3))
    try encodeOrdinary(bytes, appendingTo: &encoded)
    encoded.withUnsafeBufferPointer { tokens in
      output.append(contentsOf: tokens)
    }
  }

  public mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError) {
    let originalCount = output.count
    do {
      try encodeOrdinary(bytes, range: 0..<bytes.count, into: &output)
    } catch {
      output.restoreCount(originalCount)
      throw error
    }
  }

  public mutating func encodeOrdinary(_ text: String) throws(TokenizerError) -> [TokenID] {
    try encodeOrdinary(Array(text.utf8))
  }

  public mutating func encode(
    _ bytes: [UInt8],
    specialTokenPolicy: SpecialTokenPolicy = .disallow
  ) throws(TokenizerError) -> [TokenID] {
    var output = TokenBuffer(minimumCapacity: max(1, bytes.count / 3))
    try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try encode(
        buffer,
        specialTokenPolicy: specialTokenPolicy,
        appendingTo: &output
      )
    }
    return output.copyTokens()
  }

  public mutating func encode(
    _ bytes: UnsafeBufferPointer<UInt8>,
    specialTokenPolicy: SpecialTokenPolicy = .disallow,
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError) {
    var encoded = TokenBuffer(minimumCapacity: max(1, bytes.count / 3))
    try encode(
      bytes,
      specialTokenPolicy: specialTokenPolicy,
      appendingTo: &encoded
    )
    encoded.withUnsafeBufferPointer { tokens in
      output.append(contentsOf: tokens)
    }
  }

  public mutating func encode(
    _ bytes: UnsafeBufferPointer<UInt8>,
    specialTokenPolicy: SpecialTokenPolicy = .disallow,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError) {
    let originalCount = output.count
    do {
      try encodeTransactional(
        bytes,
        specialTokenPolicy: specialTokenPolicy,
        appendingTo: &output
      )
    } catch {
      output.restoreCount(originalCount)
      throw error
    }
  }

  private mutating func encodeTransactional(
    _ bytes: UnsafeBufferPointer<UInt8>,
    specialTokenPolicy: SpecialTokenPolicy,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError) {
    guard !model.specialTokens.isEmpty else {
      return try encodeOrdinary(bytes, range: 0..<bytes.count, into: &output)
    }

    var segmentStart = 0
    var position = 0
    while position < bytes.count {
      guard let special = matchingSpecialToken(in: bytes, at: position) else {
        position += 1
        continue
      }
      guard specialTokenPolicy.allows(special.id) else {
        throw TokenizerError.disallowedSpecialToken(id: special.id)
      }
      if segmentStart < position {
        let segment = UnsafeBufferPointer(rebasing: bytes[segmentStart..<position])
        try encodeOrdinary(segment, range: 0..<segment.count, into: &output)
      }
      output.withAppender(maximumAdditionalCount: 1) { cursor in
        cursor.appendToken(rawValue: special.id.rawValue)
      }
      position += special.bytes.count
      segmentStart = position
    }
    if segmentStart < bytes.count {
      let segment = UnsafeBufferPointer(rebasing: bytes[segmentStart..<bytes.count])
      try encodeOrdinary(segment, range: 0..<segment.count, into: &output)
    }
  }

  public mutating func encode(
    _ text: String,
    specialTokenPolicy: SpecialTokenPolicy = .disallow
  ) throws(TokenizerError) -> [TokenID] {
    try encode(Array(text.utf8), specialTokenPolicy: specialTokenPolicy)
  }

  private mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    into output: inout TokenBuffer
  ) throws(TokenizerError) {
    guard !range.isEmpty else {
      return
    }
    let segment = UnsafeBufferPointer(rebasing: bytes[range])
    try encodeSegment(segment, into: &output)
  }

  private mutating func encodeSegment(
    _ bytes: UnsafeBufferPointer<UInt8>,
    into output: inout TokenBuffer
  ) throws(TokenizerError) {
    let batchBaseAddress = pretokenScratch.batchEntries
    let boundaryBaseAddress = pretokenScratch.boundaries
    var position = 0
    while position < bytes.count {
      let batchInputStart = position
      let fillResult = try pretokenizer.fillPretokenBatch(
        in: bytes,
        startingAt: position,
        into: batchBaseAddress,
        boundaries: boundaryBaseAddress,
        prefetchCache: shortCache
      )
      let batchCount = fillResult.count
      position = fillResult.endPosition

      let maximumBatchOutput = position - batchInputStart
      output.withAppender(maximumAdditionalCount: maximumBatchOutput) { cursor in
        var batchIndex = 0
        var outputCount = cursor.count
        var prefetchIndex = 0
        while prefetchIndex < min(16, batchCount) {
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: prefetchIndex).pointee.metadata,
            locality: .level1
          )
          prefetchIndex += 1
        }
        batchIndex = 0
        while batchIndex &+ 3 < batchCount {
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 16).pointee.metadata,
            locality: .level1
          )
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 17).pointee.metadata,
            locality: .level1
          )
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 18).pointee.metadata,
            locality: .level1
          )
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 19).pointee.metadata,
            locality: .level1
          )
          let firstEntry = batchBaseAddress.advanced(by: batchIndex).pointee
          let secondEntry = batchBaseAddress.advanced(by: batchIndex &+ 1).pointee
          let thirdEntry = batchBaseAddress.advanced(by: batchIndex &+ 2).pointee
          let fourthEntry = batchBaseAddress.advanced(by: batchIndex &+ 3).pointee
          let firstProbe = shortCache.probePair(
            low: firstEntry.keyLow,
            high: firstEntry.keyHigh,
            hash: firstEntry.metadata
          )
          let secondProbe = shortCache.probePair(
            low: secondEntry.keyLow,
            high: secondEntry.keyHigh,
            hash: secondEntry.metadata
          )
          let thirdProbe = shortCache.probePair(
            low: thirdEntry.keyLow,
            high: thirdEntry.keyHigh,
            hash: thirdEntry.metadata
          )
          let fourthProbe = shortCache.probePair(
            low: fourthEntry.keyLow,
            high: fourthEntry.keyHigh,
            hash: fourthEntry.metadata
          )

          let firstIsFast = Self.all(
            firstProbe.foundMask != 0,
            firstEntry.keyHigh != 0,
            firstProbe.value.value & 0x80 == 0
          )
          let secondIsFast = Self.all(
            secondProbe.foundMask != 0,
            secondEntry.keyHigh != 0,
            secondProbe.value.value & 0x80 == 0
          )
          let thirdIsFast = Self.all(
            thirdProbe.foundMask != 0,
            thirdEntry.keyHigh != 0,
            thirdProbe.value.value & 0x80 == 0
          )
          let fourthIsFast = Self.all(
            fourthProbe.foundMask != 0,
            fourthEntry.keyHigh != 0,
            fourthProbe.value.value & 0x80 == 0
          )
          guard Self.all(firstIsFast, secondIsFast, thirdIsFast, fourthIsFast) else {
            break
          }

          cursor.writeInlineTokens(
            value: firstProbe.value.value,
            extensionValue: firstProbe.value.extensionValue,
            at: outputCount
          )
          outputCount &+= firstProbe.value.tokenCount
          cursor.writeInlineTokens(
            value: secondProbe.value.value,
            extensionValue: secondProbe.value.extensionValue,
            at: outputCount
          )
          outputCount &+= secondProbe.value.tokenCount
          cursor.writeInlineTokens(
            value: thirdProbe.value.value,
            extensionValue: thirdProbe.value.extensionValue,
            at: outputCount
          )
          outputCount &+= thirdProbe.value.tokenCount
          cursor.writeInlineTokens(
            value: fourthProbe.value.value,
            extensionValue: fourthProbe.value.extensionValue,
            at: outputCount
          )
          outputCount &+= fourthProbe.value.tokenCount
          batchIndex &+= 4
        }
        while batchIndex &+ 1 < batchCount {
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 16).pointee.metadata,
            locality: .level1
          )
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 17).pointee.metadata,
            locality: .level1
          )
          let firstEntry = batchBaseAddress.advanced(by: batchIndex).pointee
          let secondEntry = batchBaseAddress.advanced(by: batchIndex &+ 1).pointee
          let firstProbe = shortCache.probePair(
            low: firstEntry.keyLow,
            high: firstEntry.keyHigh,
            hash: firstEntry.metadata
          )
          let secondProbe = shortCache.probePair(
            low: secondEntry.keyLow,
            high: secondEntry.keyHigh,
            hash: secondEntry.metadata
          )

          let firstIsFast = Self.all(
            firstProbe.foundMask != 0,
            firstEntry.keyHigh != 0,
            firstProbe.value.value & 0x80 == 0
          )
          cursor.writeInlineTokens(
            value: firstProbe.value.value,
            extensionValue: firstProbe.value.extensionValue,
            at: outputCount
          )
          if firstIsFast {
            outputCount &+= firstProbe.value.tokenCount
          } else {
            cursor.advance(by: outputCount - cursor.count)
            encodeSlow(entry: firstEntry, probed: firstProbe, bytes: bytes, into: &cursor)
            outputCount = cursor.count
            batchIndex &+= 1
            continue
          }

          let secondIsFast = Self.all(
            secondProbe.foundMask != 0,
            secondEntry.keyHigh != 0,
            secondProbe.value.value & 0x80 == 0
          )
          cursor.writeInlineTokens(
            value: secondProbe.value.value,
            extensionValue: secondProbe.value.extensionValue,
            at: outputCount
          )
          if secondIsFast {
            outputCount &+= secondProbe.value.tokenCount
          } else {
            cursor.advance(by: outputCount - cursor.count)
            encodeSlow(entry: secondEntry, probed: secondProbe, bytes: bytes, into: &cursor)
            outputCount = cursor.count
          }
          batchIndex &+= 2
        }
        while batchIndex < batchCount {
          shortCache.prefetchForRead(
            hash: batchBaseAddress.advanced(by: batchIndex &+ 16).pointee.metadata,
            locality: .level1
          )
          let entry = batchBaseAddress.advanced(by: batchIndex).pointee
          let probed = shortCache.probePair(
            low: entry.keyLow,
            high: entry.keyHigh,
            hash: entry.metadata
          )
          let isFast = Self.all(
            probed.foundMask != 0,
            entry.keyHigh != 0,
            probed.value.value & 0x80 == 0
          )
          cursor.writeInlineTokens(
            value: probed.value.value,
            extensionValue: probed.value.extensionValue,
            at: outputCount
          )
          if isFast {
            outputCount &+= probed.value.tokenCount
          } else {
            cursor.advance(by: outputCount - cursor.count)
            encodeSlow(entry: entry, probed: probed, bytes: bytes, into: &cursor)
            outputCount = cursor.count
          }
          batchIndex &+= 1
        }
        cursor.advance(by: outputCount - cursor.count)
      }
    }
  }

  @inline(never)
  private mutating func encodeSlow(
    entry: PretokenBatchEntry,
    probed: ShortPretokenProbeResult,
    bytes: UnsafeBufferPointer<UInt8>,
    into cursor: inout TokenOutputCursor
  ) {
    if entry.keyHigh != 0 {
      let key = ShortPretokenKey(low: entry.keyLow, high: entry.keyHigh)
      let count = Int(entry.keyHigh >> 56)
      let pretokenRange = entry.start..<(entry.start + count)
      if probed.foundMask != 0 {
        probed.value.appendTokens(arena: tokenArena, to: &cursor)
        return
      }
      if let cached = shortCache.valueAfterHomePair(for: key, hash: entry.metadata) {
        cached.appendTokens(arena: tokenArena, to: &cursor)
        return
      }

      var symbols = InlineArray<16, UInt32> { _ in 0 }
      let symbolCount = model.encodeShort(
        bytes: bytes,
        range: pretokenRange,
        symbols: &symbols
      )
      let value = PackedTokenValue.pack(
        symbols: symbols,
        count: symbolCount,
        arena: &tokenArena
      )
      shortCache.insert(value, for: key)
      value.appendTokens(arena: tokenArena, to: &cursor)
      return
    }

    let pretokenRange = entry.start..<Int(entry.metadata)
    let hash = LongPretokenCache.hash(bytes: bytes, range: pretokenRange)
    if let cached = longCache.value(
      for: bytes,
      range: pretokenRange,
      hash: hash
    ) {
      cached.appendTokens(arena: tokenArena, to: &cursor)
      return
    }

    let count = mergeWorkspace.encode(
      bytes: bytes,
      range: pretokenRange,
      byteTokenIDs: model.singleByteTokenIDs,
      pairRanks: model.pairRanks
    )
    let tokenOffset = tokenArena.count
    var index = 0
    while index < count {
      let token = mergeWorkspace.symbols[index]
      tokenArena.append(token)
      cursor.appendToken(rawValue: token)
      index += 1
    }
    longCache.insert(
      bytes: bytes,
      range: pretokenRange,
      hash: hash,
      tokenOffset: tokenOffset,
      tokenCount: count
    )
  }

  private mutating func seedShortCache() {
    var symbols = InlineArray<16, UInt32> { _ in 0 }
    model.tokenStorage.withUnsafeBufferPointer { buffer in
      var tokenIndex = 0
      while tokenIndex < model.tokenCount {
        let range = model.tokenRange(at: tokenIndex)
        if let key = ShortPretokenKey(bytes: buffer, range: range),
          shortCache.value(for: key) == nil
        {
          let count = model.encodeShort(
            bytes: buffer,
            range: range,
            symbols: &symbols
          )
          let value = PackedTokenValue.pack(
            symbols: symbols,
            count: count,
            arena: &tokenArena
          )
          shortCache.insert(value, for: key)
        }
        tokenIndex += 1
      }
    }
  }

  @_transparent
  private static func all(_ first: Bool, _ second: Bool, _ third: Bool) -> Bool {
    let firstBit = unsafeBitCast(first, to: UInt8.self)
    let secondBit = unsafeBitCast(second, to: UInt8.self)
    let thirdBit = unsafeBitCast(third, to: UInt8.self)
    return firstBit & secondBit & thirdBit != 0
  }

  @_transparent
  private static func all(
    _ first: Bool,
    _ second: Bool,
    _ third: Bool,
    _ fourth: Bool
  ) -> Bool {
    let firstBit = unsafeBitCast(first, to: UInt8.self)
    let secondBit = unsafeBitCast(second, to: UInt8.self)
    let thirdBit = unsafeBitCast(third, to: UInt8.self)
    let fourthBit = unsafeBitCast(fourth, to: UInt8.self)
    return firstBit & secondBit & thirdBit & fourthBit != 0
  }

  @inline(__always)
  private func matchingSpecialToken(
    in bytes: UnsafeBufferPointer<UInt8>,
    at position: Int
  ) -> SpecialToken? {
    for special in model.specialTokens {
      guard special.bytes.count <= bytes.count - position else {
        continue
      }
      var offset = 0
      while offset < special.bytes.count,
        bytes[position + offset] == special.bytes[offset]
      {
        offset += 1
      }
      if offset == special.bytes.count {
        return special
      }
    }
    return nil
  }
}
