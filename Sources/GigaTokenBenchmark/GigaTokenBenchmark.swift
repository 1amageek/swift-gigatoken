import Foundation
import GigaToken
import GigaTokenCore

@main
struct GigaTokenBenchmark {
  static func main() throws {
    let options = try BenchmarkOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let modelURL = URL(fileURLWithPath: options.modelPath)
    let inputURL = URL(fileURLWithPath: options.inputPath)
    let input = try Data(contentsOf: inputURL, options: [.mappedIfSafe])

    let buildStart = Date.timeIntervalSinceReferenceDate
    let model = try TiktokenModelLoader.r50kBase().model(at: modelURL)
    var tokenizer = GigaTokenizer(model: model)
    let modelDuration = Date.timeIntervalSinceReferenceDate - buildStart

    var tokens = TokenBuffer(minimumCapacity: max(1, input.count / 3))
    var coldDuration = 0.0
    var warmDurations: [Double] = []
    warmDurations.reserveCapacity(options.iterations)
    try input.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      let coldStart = Date.timeIntervalSinceReferenceDate
      try tokenizer.encodeOrdinary(bytes, appendingTo: &tokens)
      coldDuration = Date.timeIntervalSinceReferenceDate - coldStart

      for _ in 0..<options.iterations {
        tokens.removeAll(keepingCapacity: true)
        let start = Date.timeIntervalSinceReferenceDate
        try tokenizer.encodeOrdinary(bytes, appendingTo: &tokens)
        warmDurations.append(Date.timeIntervalSinceReferenceDate - start)
      }
    }

    let coldSeconds = coldDuration
    warmDurations.sort()
    let warmSeconds = warmDurations[warmDurations.count / 2]
    let storageMetrics = tokenizer.storageMetrics
    let result = BenchmarkResult(
      implementation: "swift-gigatoken",
      bytes: input.count,
      tokens: tokens.count,
      tokenChecksum: tokens.withUnsafeBufferPointer(tokenChecksum),
      modelBuildSeconds: modelDuration,
      coldSeconds: coldSeconds,
      coldMegabytesPerSecond: Double(input.count) / coldSeconds / 1_000_000,
      warmMedianSeconds: warmSeconds,
      warmMegabytesPerSecond: Double(input.count) / warmSeconds / 1_000_000,
      iterations: options.iterations,
      shortCacheEntryCount: storageMetrics.shortCacheEntryCount,
      shortCacheSlotCapacity: storageMetrics.shortCacheSlotCapacity,
      longCacheEntryCount: storageMetrics.longCacheEntryCount,
      longCacheSlotCapacity: storageMetrics.longCacheSlotCapacity,
      longCacheStoredByteCount: storageMetrics.longCacheStoredByteCount,
      tokenArenaCount: storageMetrics.tokenArenaCount,
      tokenArenaCapacity: storageMetrics.tokenArenaCapacity
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(result))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private static func tokenChecksum(_ tokens: UnsafeBufferPointer<TokenID>) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for token in tokens {
      var value = token.rawValue
      for _ in 0..<4 {
        hash ^= UInt64(value & 0xFF)
        hash = hash &* 0x100_0000_01B3
        value >>= 8
      }
    }
    return String(hash, radix: 16, uppercase: false)
  }
}

private struct BenchmarkOptions {
  let modelPath: String
  let inputPath: String
  let iterations: Int

  init(arguments: [String]) throws {
    var modelPath: String?
    var inputPath: String?
    var iterations = 5
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--model" where index + 1 < arguments.count:
        modelPath = arguments[index + 1]
        index += 2
      case "--input" where index + 1 < arguments.count:
        inputPath = arguments[index + 1]
        index += 2
      case "--iterations" where index + 1 < arguments.count:
        guard let value = Int(arguments[index + 1]), value > 0 else {
          throw BenchmarkError.invalidIterations
        }
        iterations = value
        index += 2
      default:
        throw BenchmarkError.invalidArguments
      }
    }
    guard let modelPath, let inputPath else {
      throw BenchmarkError.invalidArguments
    }
    self.modelPath = modelPath
    self.inputPath = inputPath
    self.iterations = iterations
  }
}

private struct BenchmarkResult: Encodable {
  let implementation: String
  let bytes: Int
  let tokens: Int
  let tokenChecksum: String
  let modelBuildSeconds: Double
  let coldSeconds: Double
  let coldMegabytesPerSecond: Double
  let warmMedianSeconds: Double
  let warmMegabytesPerSecond: Double
  let iterations: Int
  let shortCacheEntryCount: Int
  let shortCacheSlotCapacity: Int
  let longCacheEntryCount: Int
  let longCacheSlotCapacity: Int
  let longCacheStoredByteCount: Int
  let tokenArenaCount: Int
  let tokenArenaCapacity: Int
}

private enum BenchmarkError: Error {
  case invalidArguments
  case invalidIterations
}
