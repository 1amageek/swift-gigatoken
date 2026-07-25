public struct BPEModel: TokenByteDecoding, Sendable {
  public let tokenCount: Int
  public let specialTokens: [SpecialToken]

  let tokenStorage: [UInt8]
  let tokenOffsets: [UInt32]
  let singleByteTokenIDs: [UInt32]
  let pairRanks: PairRankTable
  let shortTokenCount: Int

  public init(
    rankOrderedTokens: [[UInt8]],
    specialTokens: [SpecialToken] = []
  ) throws(TokenizerError) {
    guard !rankOrderedTokens.isEmpty else {
      throw TokenizerError.emptyVocabulary
    }
    guard UInt64(rankOrderedTokens.count) < UInt64(UInt32.max) else {
      throw TokenizerError.vocabularyTooLarge(count: rankOrderedTokens.count)
    }
    var storageByteCount: UInt64 = 0
    for bytes in rankOrderedTokens {
      storageByteCount += UInt64(bytes.count)
      guard storageByteCount <= UInt64(UInt32.max) else {
        throw TokenizerError.modelStorageTooLarge(byteCount: storageByteCount)
      }
    }

    var tokenStorage: [UInt8] = []
    tokenStorage.reserveCapacity(Int(storageByteCount))
    var tokenOffsets: [UInt32] = []
    tokenOffsets.reserveCapacity(rankOrderedTokens.count + 1)
    tokenOffsets.append(0)
    for bytes in rankOrderedTokens {
      tokenStorage.append(contentsOf: bytes)
      tokenOffsets.append(UInt32(tokenStorage.count))
    }

    try self.init(
      packedTokenStorage: tokenStorage,
      tokenOffsets: tokenOffsets,
      specialTokens: specialTokens
    )
  }

  public init(
    packedTokenStorage tokenStorage: [UInt8],
    tokenOffsets: [UInt32],
    specialTokens: [SpecialToken] = []
  ) throws(TokenizerError) {
    guard tokenOffsets.count >= 2 else {
      throw TokenizerError.emptyVocabulary
    }
    let tokenCount = tokenOffsets.count - 1
    guard UInt64(tokenCount) < UInt64(UInt32.max) else {
      throw TokenizerError.vocabularyTooLarge(count: tokenCount)
    }
    guard UInt64(tokenStorage.count) <= UInt64(UInt32.max) else {
      throw TokenizerError.modelStorageTooLarge(byteCount: UInt64(tokenStorage.count))
    }
    guard tokenOffsets[0] == 0 else {
      throw TokenizerError.invalidTokenOffsets(index: 0)
    }
    var offsetIndex = 1
    while offsetIndex < tokenOffsets.count {
      guard tokenOffsets[offsetIndex] >= tokenOffsets[offsetIndex - 1] else {
        throw TokenizerError.invalidTokenOffsets(index: offsetIndex)
      }
      guard tokenOffsets[offsetIndex] > tokenOffsets[offsetIndex - 1] else {
        throw TokenizerError.emptyToken(id: TokenID(rawValue: UInt32(offsetIndex - 1)))
      }
      offsetIndex += 1
    }
    guard tokenOffsets.last == UInt32(tokenStorage.count) else {
      throw TokenizerError.invalidTokenOffsets(index: tokenOffsets.count - 1)
    }

    for specialIndex in specialTokens.indices {
      let special = specialTokens[specialIndex]
      guard !special.bytes.isEmpty else {
        throw TokenizerError.emptySpecialToken(id: special.id)
      }
      if let invalidOffset = special.bytes.withUnsafeBufferPointer(
        UTF8Validation.firstInvalidOffset
      ) {
        throw TokenizerError.invalidUTF8(offset: invalidOffset)
      }
      guard UInt64(special.id.rawValue) >= UInt64(tokenCount) else {
        throw TokenizerError.specialTokenIDCollidesWithVocabulary(id: special.id)
      }
      for previousIndex in specialTokens.indices where previousIndex < specialIndex {
        let previous = specialTokens[previousIndex]
        guard previous.id != special.id else {
          throw TokenizerError.duplicateSpecialTokenID(id: special.id)
        }
        guard previous.bytes != special.bytes else {
          throw TokenizerError.duplicateSpecialTokenBytes(bytes: special.bytes)
        }
      }
    }

    var byteIDs = [UInt32](repeating: UInt32.max, count: 256)
    var shortTokenCount = 0
    var tokenIndex = try PackedTokenIndex(expectedCount: tokenCount)
    var table = try PairRankTable(expectedCount: max(1, tokenCount - 256))
    var workspace = BPEMergeWorkspace()
    try tokenStorage.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      var index = 0
      while index < tokenCount {
        let lowerBound = Int(tokenOffsets[index])
        let upperBound = Int(tokenOffsets[index + 1])
        let range = lowerBound..<upperBound
        let id = TokenID(rawValue: UInt32(index))
        if let first = tokenIndex.insert(
          tokenIndex: UInt32(index),
          storage: buffer,
          offsets: tokenOffsets
        ) {
          throw TokenizerError.duplicateToken(
            bytes: Array(buffer[range]),
            first: TokenID(rawValue: first),
            duplicate: id
          )
        }
        if range.count == 1 {
          byteIDs[Int(buffer[lowerBound])] = UInt32(index)
        }
        if !range.isEmpty, range.count <= 15 {
          shortTokenCount += 1
        }
        index += 1
      }
      for byte in UInt16(0)...UInt16(255) where byteIDs[Int(byte)] == UInt32.max {
        throw TokenizerError.missingSingleByteToken(byte: UInt8(byte))
      }

      var mergeIndex = 0
      while mergeIndex < tokenCount {
        let range = Int(tokenOffsets[mergeIndex])..<Int(tokenOffsets[mergeIndex + 1])
        if range.count >= 2 {
          let symbolCount = workspace.encode(
            bytes: buffer,
            range: range,
            byteTokenIDs: byteIDs,
            pairRanks: table
          )
          guard symbolCount == 2 else {
            throw TokenizerError.invalidMerge(
              token: TokenID(rawValue: UInt32(mergeIndex)),
              remainingSymbols: symbolCount
            )
          }
          try table.insert(
            left: TokenID(rawValue: workspace.symbols[0]),
            right: TokenID(rawValue: workspace.symbols[1]),
            merged: TokenID(rawValue: UInt32(mergeIndex))
          )
        }
        mergeIndex += 1
      }
    }

    self.tokenCount = tokenCount
    self.tokenStorage = tokenStorage
    self.tokenOffsets = tokenOffsets
    self.specialTokens = specialTokens.sorted {
      if $0.bytes.count == $1.bytes.count {
        return $0.id < $1.id
      }
      return $0.bytes.count > $1.bytes.count
    }
    singleByteTokenIDs = byteIDs
    pairRanks = table
    self.shortTokenCount = shortTokenCount
  }

  public func bytes(for token: TokenID) throws(TokenizerError) -> [UInt8] {
    if UInt64(token.rawValue) < UInt64(tokenCount) {
      let index = Int(token.rawValue)
      return Array(tokenStorage[Int(tokenOffsets[index])..<Int(tokenOffsets[index + 1])])
    }
    if let special = specialTokens.first(where: { $0.id == token }) {
      return special.bytes
    }
    throw TokenizerError.unknownToken(id: token)
  }

  public func withTokenBytes<Result, Failure: Error>(
    for token: TokenID,
    _ body: (UnsafeBufferPointer<UInt8>) throws(Failure) -> Result
  ) throws(TokenByteAccessError<Failure>) -> Result {
    if UInt64(token.rawValue) < UInt64(tokenCount) {
      let index = Int(token.rawValue)
      let range = Int(tokenOffsets[index])..<Int(tokenOffsets[index + 1])
      do {
        return try tokenStorage.withUnsafeBufferPointer { storage throws(Failure) in
          try body(UnsafeBufferPointer(rebasing: storage[range]))
        }
      } catch {
        throw .consumer(error)
      }
    }
    if let special = specialTokens.first(where: { $0.id == token }) {
      do {
        return try special.bytes.withUnsafeBufferPointer(body)
      } catch {
        throw .consumer(error)
      }
    }
    throw .tokenizer(.unknownToken(id: token))
  }

  public func decode(_ tokens: [TokenID]) throws(TokenizerError) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(tokens.count * 4)
    try tokens.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try decode(buffer, appendingTo: &result)
    }
    return result
  }

  public func decode(
    _ tokens: UnsafeBufferPointer<TokenID>,
    appendingTo output: inout [UInt8]
  ) throws(TokenizerError) {
    for token in tokens where UInt64(token.rawValue) >= UInt64(tokenCount) {
      guard specialTokens.contains(where: { $0.id == token }) else {
        throw TokenizerError.unknownToken(id: token)
      }
    }

    for token in tokens {
      if UInt64(token.rawValue) < UInt64(tokenCount) {
        let index = Int(token.rawValue)
        output.append(
          contentsOf: tokenStorage[Int(tokenOffsets[index])..<Int(tokenOffsets[index + 1])]
        )
        continue
      }
      guard let special = specialTokens.first(where: { $0.id == token }) else {
        preconditionFailure("Token validation and decoding diverged")
      }
      output.append(contentsOf: special.bytes)
    }
  }

  @inline(__always)
  func tokenRange(at index: Int) -> Range<Int> {
    Int(tokenOffsets[index])..<Int(tokenOffsets[index + 1])
  }

  @inline(__always)
  func encodeShort(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    symbols: inout InlineArray<16, UInt32>
  ) -> Int {
    let count = range.count
    var index = 0
    while index < count {
      symbols[index] = singleByteTokenIDs[Int(bytes[range.lowerBound + index])]
      index += 1
    }
    guard count > 1 else {
      return count
    }

    var next = InlineArray<16, UInt8> { UInt8($0 + 1) }
    var previous = InlineArray<16, UInt8> { UInt8(truncatingIfNeeded: $0 - 1) }
    var ranks = InlineArray<16, UInt32> { _ in UInt32.max }
    index = 0
    while index < count - 1 {
      ranks[index] = pairRanks.mergedTokenRaw(
        left: symbols[index],
        right: symbols[index + 1]
      )
      index += 1
    }

    while true {
      var bestRank = UInt32.max
      var bestIndex = 0
      index = 0
      while index < count - 1 {
        let rank = ranks[index]
        if rank < bestRank {
          bestRank = rank
          bestIndex = index
        }
        index += 1
      }
      guard bestRank != UInt32.max else {
        break
      }

      let dead = Int(next[bestIndex])
      let newRight = Int(next[dead])
      let left = Int(previous[bestIndex])
      symbols[bestIndex] = bestRank
      next[bestIndex] = UInt8(newRight)
      ranks[dead] = UInt32.max
      if newRight < count {
        previous[newRight] = UInt8(bestIndex)
        ranks[bestIndex] = pairRanks.mergedTokenRaw(
          left: bestRank,
          right: symbols[newRight]
        )
      } else {
        ranks[bestIndex] = UInt32.max
      }
      if left < count {
        ranks[left] = pairRanks.mergedTokenRaw(
          left: symbols[left],
          right: bestRank
        )
      }
    }

    var writeIndex = 0
    index = 0
    while index < count {
      symbols[writeIndex] = symbols[index]
      writeIndex += 1
      index = Int(next[index])
    }
    return writeIndex
  }
}
