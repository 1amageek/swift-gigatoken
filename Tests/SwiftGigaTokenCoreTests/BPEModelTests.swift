import Testing

@testable import SwiftGigaTokenCore

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

    var decoded = [UInt8(0x7A)]
    let tokens = [TokenID(rawValue: 97), TokenID(rawValue: 999)]
    #expect(throws: TokenizerError.unknownToken(id: TokenID(rawValue: 999))) {
      try tokens.withUnsafeBufferPointer { buffer throws(TokenizerError) in
        try model.decode(buffer, appendingTo: &decoded)
      }
    }
    #expect(decoded == [0x7A])
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
