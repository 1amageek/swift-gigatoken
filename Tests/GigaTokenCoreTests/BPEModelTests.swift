import Testing

@testable import GigaTokenCore

@Suite("BPE model")
struct BPEModelTests {
  @Test("Merge priority follows token rank")
  func mergePriority() throws {
    var vocabulary = (0...255).map { [UInt8($0)] }
    vocabulary.append(Array("ab".utf8))
    vocabulary.append(Array("bc".utf8))
    vocabulary.append(Array("abc".utf8))
    let model = try BPEModel(rankOrderedTokens: vocabulary)
    var encoder = BPEEncoder(model: model)

    let tokens = try encoder.encodeOrdinary("abc")

    #expect(tokens == [TokenID(rawValue: 258)])
    #expect(try model.decode(tokens) == Array("abc".utf8))
  }

  @Test("Missing byte token is rejected")
  func missingByteToken() {
    #expect(throws: TokenizerError.missingSingleByteToken(byte: 255)) {
      _ = try BPEModel(rankOrderedTokens: (0..<255).map { [UInt8($0)] })
    }
  }

  @Test("Vocabulary construction reports structural failures exactly")
  func vocabularyFailures() {
    #expect(throws: TokenizerError.emptyVocabulary) {
      _ = try BPEModel(rankOrderedTokens: [])
    }

    var duplicateVocabulary = (0...255).map { [UInt8($0)] }
    duplicateVocabulary.append([0])
    #expect(
      throws: TokenizerError.duplicateToken(
        bytes: [0],
        first: TokenID(rawValue: 0),
        duplicate: TokenID(rawValue: 256)
      )
    ) {
      _ = try BPEModel(rankOrderedTokens: duplicateVocabulary)
    }

    var invalidMergeVocabulary = (0...255).map { [UInt8($0)] }
    invalidMergeVocabulary.append(Array("abc".utf8))
    #expect(
      throws: TokenizerError.invalidMerge(
        token: TokenID(rawValue: 256),
        remainingSymbols: 3
      )
    ) {
      _ = try BPEModel(rankOrderedTokens: invalidMergeVocabulary)
    }
  }

  @Test("Caller-owned output buffers append and can be reused")
  func reusableOutputBuffer() throws {
    var vocabulary = (0...255).map { [UInt8($0)] }
    vocabulary.append([0x61, 0x62])
    let model = try BPEModel(rankOrderedTokens: vocabulary)
    var encoder = BPEEncoder(model: model)
    var output = [TokenID(rawValue: 7)]

    try encoder.encodeOrdinary([0x61, 0x62], appendingTo: &output)

    #expect(output == [TokenID(rawValue: 7), TokenID(rawValue: 256)])
    output.removeAll(keepingCapacity: true)
    try encoder.encodeOrdinary([0x61, 0x62], appendingTo: &output)
    #expect(output == [TokenID(rawValue: 256)])
  }

  @Test("Raw token IDs borrow the caller-owned output allocation")
  func rawTokenBufferView() throws {
    var vocabulary = (0...255).map { [UInt8($0)] }
    vocabulary.append([0x61, 0x62])
    let model = try BPEModel(rankOrderedTokens: vocabulary)
    var encoder = BPEEncoder(model: model)
    var output = TokenBuffer(minimumCapacity: 8)

    try [UInt8(0x61), 0x62, 0x20].withUnsafeBufferPointer { bytes in
      try encoder.encodeOrdinary(bytes, appendingTo: &output)
    }

    output.withUnsafeRawTokenIDs { tokenIDs in
      #expect(Array(tokenIDs) == [256, 32])
    }
    var propagatedBorrowFailure = false
    do {
      try output.withUnsafeRawTokenIDs(rejectBorrowedTokenIDs)
    } catch BorrowFailure.rejected {
      propagatedBorrowFailure = true
    }
    #expect(propagatedBorrowFailure)
    #expect(output.capacity == 8)
  }

  @Test("Packed model validates offsets and exposes scoped token bytes")
  func packedStorageContract() throws {
    let vocabulary = (0...255).map { [UInt8($0)] }
    let storage = vocabulary.flatMap { $0 }
    let offsets = (0...256).map(UInt32.init)
    let model = try BPEModel(
      packedTokenStorage: storage,
      tokenOffsets: offsets
    )

    let byte = try model.withTokenBytes(for: TokenID(rawValue: 97)) { bytes in
      bytes[0]
    }
    #expect(byte == 97)
    var consumerFailurePropagated = false
    do {
      try model.withTokenBytes(
        for: TokenID(rawValue: 97),
        rejectBorrowedTokenBytes
      )
    } catch .consumer(.rejected) {
      consumerFailurePropagated = true
    } catch {
      Issue.record("Unexpected token byte access error: \(error)")
    }
    #expect(consumerFailurePropagated)

    var lookupFailurePropagated = false
    do {
      try model.withTokenBytes(for: TokenID(rawValue: 999)) { _ in }
    } catch .tokenizer(.unknownToken(id: TokenID(rawValue: 999))) {
      lookupFailurePropagated = true
    } catch {
      Issue.record("Unexpected token byte lookup error: \(error)")
    }
    #expect(lookupFailurePropagated)
    #expect(throws: TokenizerError.invalidTokenOffsets(index: 2)) {
      _ = try BPEModel(
        packedTokenStorage: storage,
        tokenOffsets: [0, 2, 1]
      )
    }
    #expect(throws: TokenizerError.invalidTokenOffsets(index: 0)) {
      _ = try BPEModel(
        packedTokenStorage: [0x61],
        tokenOffsets: [1, 1]
      )
    }
    #expect(throws: TokenizerError.invalidTokenOffsets(index: 1)) {
      _ = try BPEModel(
        packedTokenStorage: [0x61, 0x62],
        tokenOffsets: [0, 1]
      )
    }
    #expect(throws: TokenizerError.emptyToken(id: TokenID(rawValue: 1))) {
      _ = try BPEModel(
        packedTokenStorage: [0x61],
        tokenOffsets: [0, 1, 1]
      )
    }
  }

  @Test("Caller-owned buffers are unchanged after encoding and decoding failures")
  func atomicAppendingFailure() throws {
    let model = try BPEModel(rankOrderedTokens: (0...255).map { [UInt8($0)] })
    var encoder = BPEEncoder(model: model)
    var encoded = TokenBuffer()
    try [UInt8(0x61)].withUnsafeBufferPointer { bytes throws(TokenizerError) in
      try encoder.encodeOrdinary(bytes, appendingTo: &encoded)
    }
    let originalTokens = encoded.copyTokens()
    var invalid = Array(repeating: UInt8(0x61), count: 256)
    invalid.append(0xFF)

    #expect(throws: TokenizerError.invalidUTF8(offset: 256)) {
      try invalid.withUnsafeBufferPointer { bytes throws(TokenizerError) in
        try encoder.encodeOrdinary(bytes, appendingTo: &encoded)
      }
    }
    #expect(encoded.copyTokens() == originalTokens)

    var arrayOutput = [TokenID(rawValue: 7)]
    #expect(throws: TokenizerError.invalidUTF8(offset: 256)) {
      try encoder.encodeOrdinary(invalid, appendingTo: &arrayOutput)
    }
    #expect(arrayOutput == [TokenID(rawValue: 7)])

    var decoded = [UInt8(0x7A)]
    let tokens = [TokenID(rawValue: 97), TokenID(rawValue: 999)]
    #expect(throws: TokenizerError.unknownToken(id: TokenID(rawValue: 999))) {
      try tokens.withUnsafeBufferPointer { buffer throws(TokenizerError) in
        try model.decode(buffer, appendingTo: &decoded)
      }
    }
    #expect(decoded == [0x7A])
  }

  @Test("Speculative inline stores retain exact logical tails")
  func exactInlineStoreTails() {
    for tokenCount in 1...3 {
      var output = TokenBuffer(minimumCapacity: tokenCount)
      output.withAppender(maximumAdditionalCount: tokenCount) { cursor in
        var value = UInt64(tokenCount) | (UInt64(11) << 8)
        var extensionValue: UInt64 = 0
        if tokenCount >= 2 {
          value |= UInt64(22) << 32
        }
        if tokenCount >= 3 {
          extensionValue = UInt64(33)
        }
        cursor.writeInlineTokens(value: value, extensionValue: extensionValue)
        cursor.advance(by: tokenCount)
      }
      let expected = [UInt32(11), 22, 33].prefix(tokenCount).map(TokenID.init(rawValue:))
      #expect(output.copyTokens() == expected)
      #expect(output.count == tokenCount)
      #expect(output.capacity >= tokenCount + 3)
    }

    var groupedOutput = TokenBuffer(minimumCapacity: 10)
    groupedOutput.withAppender(maximumAdditionalCount: 10) { cursor in
      let endOffset = unsafe cursor.writeUncheckedInlineTokenGroup(
        values: SIMD4(
          1 | (11 << 8),
          2 | (21 << 8) | (22 << 32),
          3 | (31 << 8) | (32 << 32),
          4 | (41 << 8) | (42 << 32)
        ),
        extensionValues: SIMD4(0, 0, 33, 43 | (44 << 32)),
        at: 0
      )
      cursor.advance(by: endOffset)
    }
    #expect(
      groupedOutput.withUnsafeRawTokenIDs { Array($0) }
        == [11, 21, 22, 31, 32, 33, 41, 42, 43, 44]
    )
  }
}

private enum BorrowFailure: Error {
  case rejected
}

private func rejectBorrowedTokenIDs(
  _ tokenIDs: UnsafeBufferPointer<UInt32>
) throws {
  _ = tokenIDs
  throw BorrowFailure.rejected
}

private func rejectBorrowedTokenBytes(
  _ bytes: UnsafeBufferPointer<UInt8>
) throws(BorrowFailure) {
  _ = bytes
  throw .rejected
}
