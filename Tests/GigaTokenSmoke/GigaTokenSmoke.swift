import GigaTokenCore

@main
struct GigaTokenSmoke {
  static func main() {
    do {
      var vocabulary = (0...255).map { [UInt8($0)] }
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
        rankOrderedTokens: (0...255).map { [UInt8($0)] },
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
    } catch {
      fatalError("Tokenizer smoke test failed")
    }
  }
}
