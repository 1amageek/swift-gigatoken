import Foundation
import SwiftGigaTokenCore
import Testing

@testable import SwiftGigaToken

@Suite("r50k parity")
struct R50KParityTests {
  private static let fixtures: [(String, [UInt32])] = [
    ("Hello, world!", [15496, 11, 995, 0]),
    (
      "The quick brown fox jumps over the lazy dog.",
      [464, 2068, 7586, 21831, 18045, 625, 262, 16931, 3290, 13]
    ),
    ("", []),
    ("日本語テスト", [33768, 98, 17312, 105, 45739, 252, 24336, 43302]),
  ]

  @Test("Encoding matches r50k_base token IDs", arguments: fixtures)
  func encodeParity(fixture: (String, [UInt32])) throws {
    var tokenizer = try tokenizer()
    let actual = try tokenizer.encodeOrdinary(fixture.0).map(\.rawValue)

    #expect(actual == fixture.1)
  }

  @Test("Decode round trips representative text", arguments: fixtures.map(\.0))
  func decodeRoundTrip(text: String) throws {
    var tokenizer = try tokenizer()
    let encoded = try tokenizer.encodeOrdinary(text)

    #expect(try tokenizer.decode(encoded) == text)
  }

  @Test("End-of-text follows explicit special-token policy")
  func specialToken() throws {
    var tokenizer = try tokenizer()
    let text = "Hello<|endoftext|>world"
    #expect(throws: TokenizerError.disallowedSpecialToken(id: TokenID(rawValue: 50_256))) {
      _ = try tokenizer.encode(text)
    }
    let tokens = try tokenizer.encode(text, specialTokenPolicy: .allowAll)
    #expect(tokens.contains(TokenID(rawValue: 50_256)))
    #expect(try tokenizer.decode(tokens) == text)
  }

  @Test("Generated Unicode and boundary corpus matches tiktoken")
  func generatedCorpus() throws {
    guard
      let fixtureURL = Bundle.module.url(
        forResource: "r50k_parity",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    else {
      throw FixtureError.missingParityCorpus
    }
    let fixtures = try JSONDecoder().decode(
      [GeneratedParityFixture].self,
      from: Data(contentsOf: fixtureURL)
    )
    var tokenizer = try tokenizer()
    for (index, fixture) in fixtures.enumerated() {
      let actual = try tokenizer.encodeOrdinary(fixture.text).map(\.rawValue)
      #expect(actual == fixture.tokens, "Fixture index: \(index), text: \(fixture.text)")
    }
  }

  @Test("Malformed model files fail with typed errors")
  func malformedModels() throws {
    let loader = TiktokenModelLoader()

    #expect(throws: TokenizerError.nonDenseRank(expected: 0, actual: 1, line: 1)) {
      _ = try loader.model(at: fixtureURL(named: "invalid_non_dense"))
    }
    #expect(throws: TokenizerError.invalidBase64(line: 1)) {
      _ = try loader.model(at: fixtureURL(named: "invalid_base64"))
    }
    #expect(throws: TokenizerError.invalidModelLine(line: 1)) {
      _ = try loader.model(at: fixtureURL(named: "invalid_line"))
    }
  }

  @Test("Decode reports the exact invalid UTF-8 lead offset")
  func decodeInvalidUTF8Offset() throws {
    let model = try BPEModel(rankOrderedTokens: (0...255).map { [UInt8($0)] })
    let tokenizer = GigaTokenizer(model: model)

    #expect(throws: TokenizerError.invalidUTF8(offset: 1)) {
      _ = try tokenizer.decode([TokenID(rawValue: 97), TokenID(rawValue: 255)])
    }
  }

  @Test("Borrowed input and owned output reuse stable storage")
  func stableLowLevelStorage() throws {
    var tokenizer = try tokenizer()
    let input = Array(
      String(repeating: "The quick brown fox jumps over 12345! ", count: 32).utf8
    )
    var output = TokenBuffer(minimumCapacity: input.count)

    try input.withUnsafeBufferPointer { bytes in
      try tokenizer.encodeOrdinary(bytes, appendingTo: &output)
    }
    let expected = output.copyTokens()
    let warmMetrics = tokenizer.storageMetrics
    let warmOutputCapacity = output.capacity

    output.removeAll(keepingCapacity: true)
    try input.withUnsafeBufferPointer { bytes in
      try tokenizer.encodeOrdinary(bytes, appendingTo: &output)
    }

    #expect(output.copyTokens() == expected)
    #expect(output.capacity == warmOutputCapacity)
    #expect(tokenizer.storageMetrics == warmMetrics)
    #expect(warmMetrics.shortCacheAddressModulo64 == 0)
    #expect(warmMetrics.shortCacheAddressModuloTwoMiB == 0)
    #expect(MemoryLayout<TokenID>.stride == 4)
  }

  @Test("Long pretoken storage is owned once and reused")
  func stableLongPretokenStorage() throws {
    var tokenizer = try tokenizer()
    let input = Array(
      String(repeating: "supercalifragilisticexpialidocious ", count: 64).utf8
    )
    var output = TokenBuffer(minimumCapacity: input.count)

    try input.withUnsafeBufferPointer { bytes in
      try tokenizer.encodeOrdinary(bytes, appendingTo: &output)
    }
    let expected = output.copyTokens()
    let warmMetrics = tokenizer.storageMetrics

    output.removeAll(keepingCapacity: true)
    try input.withUnsafeBufferPointer { bytes in
      try tokenizer.encodeOrdinary(bytes, appendingTo: &output)
    }

    #expect(output.copyTokens() == expected)
    #expect(tokenizer.storageMetrics == warmMetrics)
    #expect(warmMetrics.longCacheEntryCount > 0)
    #expect(warmMetrics.longCacheStoredByteCount > 0)
  }

  private func tokenizer() throws -> GigaTokenizer {
    guard
      let modelURL = Bundle.module.url(
        forResource: "r50k_base", withExtension: "tiktoken", subdirectory: "Fixtures")
    else {
      throw FixtureError.missingModel
    }
    return try GigaTokenizer(r50kModelAt: modelURL)
  }

  private func fixtureURL(named name: String) throws -> URL {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "tiktoken",
        subdirectory: "Fixtures"
      )
    else {
      throw FixtureError.missingModel
    }
    return url
  }
}

private enum FixtureError: Error {
  case missingModel
  case missingParityCorpus
}

private struct GeneratedParityFixture: Decodable {
  let text: String
  let tokens: [UInt32]
}
