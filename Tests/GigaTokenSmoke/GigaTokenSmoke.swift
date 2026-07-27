import GigaTokenCore

@main
struct GigaTokenSmoke {
  static func main() async {
    #if hasFeature(Embedded)
      print("execution-mode: embedded-wasm")
    #elseif arch(wasm32)
      print("execution-mode: standard-wasm")
    #else
      print("execution-mode: native")
    #endif

    let fixture = runSynchronousSmoke()
    let results = await withTaskGroup(
      of: [TokenID].self,
      returning: [[TokenID]].self
    ) { group in
      for _ in 0..<8 {
        group.addTask {
          encodeForConcurrency(model: fixture.model, input: fixture.input)
        }
      }
      var successfulResults: [[TokenID]] = []
      successfulResults.reserveCapacity(8)
      for await result in group {
        successfulResults.append(result)
      }
      return successfulResults
    }
    guard results.count == 8 else {
      fatalError("Concurrent encoder task count diverged")
    }
    guard results.allSatisfy({ $0 == fixture.expected }) else {
      fatalError("Concurrent encoder results diverged")
    }
    print("concurrency-smoke: passed")
    print("gigatoken-smoke: passed")
  }

  private static func runSynchronousSmoke() -> ConcurrencyFixture {
    do {
      var vocabulary = byteVocabulary()
      vocabulary.append([0x61, 0x62])
      vocabulary.append([0x61, 0x62, 0x63])

      let model = try BPEModel(rankOrderedTokens: vocabulary)
      var encoder = BPEEncoder(model: model)
      let tokens = try encoder.encodeOrdinary([0x61, 0x62, 0x63, 0x20, 0x61, 0x62, 0x63])
      let expected = [TokenID(rawValue: 257), TokenID(rawValue: 32), TokenID(rawValue: 257)]
      guard tokens == expected else {
        fatalError("Unexpected token IDs")
      }

      let decoded = try model.decode(tokens)
      guard decoded == [0x61, 0x62, 0x63, 0x20, 0x61, 0x62, 0x63] else {
        fatalError("Unexpected decoded bytes")
      }

      let unicodeBytes = Array("日本語 🚀".utf8)
      let unicodeTokens = try encoder.encodeOrdinary(unicodeBytes)
      guard try model.decode(unicodeTokens) == unicodeBytes else {
        fatalError("Unexpected Unicode round trip")
      }

      do {
        _ = try encoder.encodeOrdinary([0x61, 0xFF])
        fatalError("Invalid UTF-8 was accepted")
      } catch TokenizerError.invalidUTF8(offset: 1) {
      }

      let special = SpecialToken(bytes: Array("<special>".utf8), id: TokenID(rawValue: 300))
      let specialModel = try BPEModel(
        rankOrderedTokens: byteVocabulary(),
        specialTokens: [special]
      )
      var specialEncoder = BPEEncoder(model: specialModel)
      do {
        _ = try specialEncoder.encode(Array("<special>".utf8), specialTokenPolicy: .disallow)
        fatalError("Disallowed special token was accepted")
      } catch TokenizerError.disallowedSpecialToken(id: special.id) {
      }
      let specialTokens = try specialEncoder.encode(
        Array("<special>".utf8),
        specialTokenPolicy: .allowAll
      )
      guard specialTokens == [special.id] else {
        fatalError("Allowed special token was not encoded")
      }

      var longInput: [UInt8] = []
      for value in 0..<256 {
        longInput.append(UInt8(0x61 + value / 26))
        longInput.append(UInt8(0x61 + value % 26))
        for shift in 2..<16 {
          longInput.append(UInt8(0x61 + ((value + shift * 17) % 26)))
        }
        longInput.append(0x20)
      }
      _ = try encoder.encodeOrdinary(longInput)
      guard encoder.storageMetrics.longCacheEntryCount > 0 else {
        fatalError("Long pretoken cache was not exercised")
      }
      guard encoder.storageMetrics.longCacheSlotCapacity > 64 else {
        fatalError("Long pretoken cache growth was not exercised")
      }
      let concurrentInput = Array(
        String(repeating: "The quick brown fox jumps over 12345! ", count: 128).utf8
      )
      let concurrentExpected = try encoder.encodeOrdinary(concurrentInput)
      return ConcurrencyFixture(
        model: model,
        input: concurrentInput,
        expected: concurrentExpected
      )
    } catch {
      fatalError("Tokenizer smoke test failed: \(error)")
    }
  }

  private static func encodeForConcurrency(
    model: BPEModel,
    input: [UInt8]
  ) -> [TokenID] {
    do {
      var encoder = BPEEncoder(model: model)
      return try encoder.encodeOrdinary(input)
    } catch {
      fatalError("Concurrent encoder failed: \(error)")
    }
  }

  private static func byteVocabulary() -> [[UInt8]] {
    var vocabulary: [[UInt8]] = []
    vocabulary.reserveCapacity(256)
    for byte in UInt16(0)...UInt16(255) {
      vocabulary.append([UInt8(byte)])
    }
    return vocabulary
  }
}

private struct ConcurrencyFixture: Sendable {
  let model: BPEModel
  let input: [UInt8]
  let expected: [TokenID]
}
