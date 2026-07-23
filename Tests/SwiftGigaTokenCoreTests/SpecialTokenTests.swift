import Testing

@testable import SwiftGigaTokenCore

@Suite("Special tokens")
struct SpecialTokenTests {
  @Test("Allowed tokens are atomic and disallowed tokens fail")
  func policies() throws {
    let vocabulary = (0...255).map { [UInt8($0)] }
    let special = SpecialToken(bytes: Array("<special>".utf8), id: TokenID(rawValue: 300))
    let model = try BPEModel(rankOrderedTokens: vocabulary, specialTokens: [special])
    var encoder = BPEEncoder(model: model)

    #expect(throws: TokenizerError.disallowedSpecialToken(id: special.id)) {
      _ = try encoder.encode("hello<special>")
    }
    let encoded = try encoder.encode("hello<special>", specialTokenPolicy: .allowAll)
    #expect(encoded.last == special.id)

    let bytes = Array("hello<special>".utf8)
    var output = TokenBuffer()
    try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try encoder.encode(buffer, specialTokenPolicy: .allowAll, appendingTo: &output)
    }
    #expect(output.withUnsafeBufferPointer { $0.last } == special.id)
  }

  @Test("Invalid special-token definitions are rejected")
  func invalidDefinitions() {
    let vocabulary = (0...255).map { [UInt8($0)] }
    let empty = SpecialToken(bytes: [], id: TokenID(rawValue: 256))
    #expect(throws: TokenizerError.emptySpecialToken(id: empty.id)) {
      _ = try BPEModel(rankOrderedTokens: vocabulary, specialTokens: [empty])
    }

    let invalidUTF8 = SpecialToken(bytes: [0xFF], id: TokenID(rawValue: 256))
    #expect(throws: TokenizerError.invalidUTF8(offset: 0)) {
      _ = try BPEModel(rankOrderedTokens: vocabulary, specialTokens: [invalidUTF8])
    }

    let collision = SpecialToken(bytes: [0x61, 0x62], id: TokenID(rawValue: 7))
    #expect(throws: TokenizerError.specialTokenIDCollidesWithVocabulary(id: collision.id)) {
      _ = try BPEModel(rankOrderedTokens: vocabulary, specialTokens: [collision])
    }

    let first = SpecialToken(bytes: [0x61, 0x62], id: TokenID(rawValue: 256))
    let duplicateID = SpecialToken(bytes: [0x63, 0x64], id: TokenID(rawValue: 256))
    #expect(throws: TokenizerError.duplicateSpecialTokenID(id: first.id)) {
      _ = try BPEModel(
        rankOrderedTokens: vocabulary,
        specialTokens: [first, duplicateID]
      )
    }

    let duplicateBytes = SpecialToken(bytes: first.bytes, id: TokenID(rawValue: 257))
    #expect(throws: TokenizerError.duplicateSpecialTokenBytes(bytes: first.bytes)) {
      _ = try BPEModel(
        rankOrderedTokens: vocabulary,
        specialTokens: [first, duplicateBytes]
      )
    }
  }

  @Test("Mixed special-token policy failure rolls back all appended tokens")
  func atomicPolicyFailure() throws {
    let vocabulary = (0...255).map { [UInt8($0)] }
    let first = SpecialToken(bytes: Array("<first>".utf8), id: TokenID(rawValue: 256))
    let second = SpecialToken(bytes: Array("<second>".utf8), id: TokenID(rawValue: 257))
    let model = try BPEModel(rankOrderedTokens: vocabulary, specialTokens: [first, second])
    var encoder = BPEEncoder(model: model)
    var output = TokenBuffer()
    try [UInt8(0x61)].withUnsafeBufferPointer { bytes throws(TokenizerError) in
      try encoder.encodeOrdinary(bytes, appendingTo: &output)
    }
    let original = output.copyTokens()
    let input = Array("text<first>more<second>".utf8)

    #expect(throws: TokenizerError.disallowedSpecialToken(id: second.id)) {
      try input.withUnsafeBufferPointer { bytes throws(TokenizerError) in
        try encoder.encode(
          bytes,
          specialTokenPolicy: .allow([first.id]),
          appendingTo: &output
        )
      }
    }
    #expect(output.copyTokens() == original)
  }
}
