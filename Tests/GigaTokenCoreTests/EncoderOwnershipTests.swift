import Testing

@testable import GigaTokenCore

@Suite("Encoder ownership")
struct EncoderOwnershipTests {
  @Test("Independent encoders share an immutable model across tasks")
  func independentEncoders() async throws {
    var vocabulary = (0...255).map { [UInt8($0)] }
    vocabulary.append([0x61, 0x62])
    vocabulary.append([0x61, 0x62, 0x63])
    let model = try BPEModel(rankOrderedTokens: vocabulary)
    let input = [UInt8(0x61), 0x62, 0x63, 0x20, 0x61, 0x62, 0x63]
    let expected = [
      TokenID(rawValue: 257),
      TokenID(rawValue: 32),
      TokenID(rawValue: 257),
    ]

    let results = try await withThrowingTaskGroup(
      of: [TokenID].self,
      returning: [[TokenID]].self
    ) { group in
      for _ in 0..<8 {
        group.addTask {
          var encoder = BPEEncoder(model: model)
          return try encoder.encodeOrdinary(input)
        }
      }

      var results: [[TokenID]] = []
      for try await result in group {
        results.append(result)
      }
      return results
    }

    #expect(results.count == 8)
    #expect(results.allSatisfy { $0 == expected })
  }
}
