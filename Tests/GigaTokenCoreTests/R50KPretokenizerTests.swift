import Foundation
import Testing

@testable import GigaTokenCore

private let externalCorpusPath: String? = {
  guard let path = ProcessInfo.processInfo.environment["GIGATOKEN_CORPUS"] else {
    return nil
  }
  return FileManager.default.fileExists(atPath: path) ? path : nil
}()

@Suite("r50k pretokenizer")
struct R50KPretokenizerTests {
  @Test("GPT-2 regex classes and contractions")
  func expectedSpans() throws {
    let text = "Hello, world! It's 2026.\n\n日本語 🚀"
    let bytes = Array(text.utf8)
    let spans = try R50KPretokenizer().spans(in: bytes)
    let pieces = spans.map { String(decoding: bytes[$0.range], as: UTF8.self) }

    #expect(
      pieces == ["Hello", ",", " world", "!", " It", "'s", " 2026", ".", "\n", "\n", "日本語", " 🚀"])
  }

  @Test("Whitespace lookahead keeps the last space with following content")
  func whitespaceLookahead() throws {
    let bytes = Array("a   b".utf8)
    let spans = try R50KPretokenizer().spans(in: bytes)
    let pieces = spans.map { String(decoding: bytes[$0.range], as: UTF8.self) }

    #expect(pieces == ["a", "  ", " b"])
  }

  @Test("Invalid UTF-8 fails explicitly")
  func invalidUTF8() {
    let invalidSequences: [[UInt8]] = [
      [0xFF],
      [0xC0, 0x80],
      [0xE0, 0x80, 0x80],
      [0xED, 0xA0, 0x80],
      [0xF4, 0x90, 0x80, 0x80],
      [0xE2, 0x82],
    ]
    for bytes in invalidSequences {
      #expect(throws: TokenizerError.invalidUTF8(offset: 0)) {
        _ = try R50KPretokenizer().spans(in: bytes)
      }
    }
  }

  @Test("Mask scanner matches scalar boundaries")
  func maskScannerParity() throws {
    let fragments = [
      "word", " ", "  ", "\n", "\t", "'s", "'ll", "'re", "'x", "42", ".", "!",
      "(", ")", "A", "z", "日本語", "é", "🚀", "\u{00A0}", "١٢",
    ]
    var state: UInt64 = 0x243F_6A88_85A3_08D3
    let prefetchCache = ShortPretokenCache(expectedCount: 1)
    for round in 0..<1_000 {
      var text = ""
      while text.utf8.count < 256 + round % 128 {
        state ^= state &<< 13
        state ^= state &>> 7
        state ^= state &<< 17
        text += fragments[Int(state % UInt64(fragments.count))]
      }
      let bytes = Array(text.utf8)
      let scalar = try R50KPretokenizer().spans(in: bytes).map(\.range.upperBound)
      var masked: [Int] = []
      try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
        let pretokenizer = R50KPretokenizer()
        let scratch = PretokenScratchStorage()
        var position = 0
        while position < buffer.count {
          var batch = InlineArray<264, PretokenBatchEntry> { _ in PretokenBatchEntry() }
          var batchSpan = batch.mutableSpan
          let result = try batchSpan.withUnsafeMutableBufferPointer {
            batchBuffer throws(TokenizerError) -> PretokenBatchFillResult in
            let result = try pretokenizer.fillPretokenBatch(
              in: buffer,
              startingAt: position,
              into: batchBuffer.baseAddress!,
              boundaries: scratch.boundaries,
              prefetchCache: prefetchCache
            )
            for index in 0..<result.count {
              let entry = batchBuffer[index]
              let end =
                entry.keyHigh == 0
                ? Int(entry.metadata)
                : entry.start + Int(entry.keyHigh >> 56)
              masked.append(end)
            }
            return result
          }
          position = result.endPosition
        }
      }
      #expect(masked == scalar, "Boundary mismatch in round \(round): \(text)")
    }
  }

  @Test(
    "External corpus mask boundaries match the scalar oracle",
    .enabled(
      if: externalCorpusPath != nil,
      "Set GIGATOKEN_CORPUS to an existing corpus path to enable this test"
    )
  )
  func externalCorpusMaskParity() throws {
    let path = try #require(externalCorpusPath)
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    try data.withUnsafeBytes { rawBuffer throws(TokenizerError) in
      let buffer = rawBuffer.bindMemory(to: UInt8.self)
      let pretokenizer = R50KPretokenizer()
      let scratch = PretokenScratchStorage()
      let prefetchCache = ShortPretokenCache(expectedCount: 1)
      var position = 0
      while position < buffer.count {
        var batch = InlineArray<264, PretokenBatchEntry> { _ in PretokenBatchEntry() }
        var batchSpan = batch.mutableSpan
        let result = try batchSpan.withUnsafeMutableBufferPointer {
          batchBuffer throws(TokenizerError) -> PretokenBatchFillResult in
          let result = try pretokenizer.fillPretokenBatch(
            in: buffer,
            startingAt: position,
            into: batchBuffer.baseAddress!,
            boundaries: scratch.boundaries,
            prefetchCache: prefetchCache
          )
          var scalarPosition = position
          for index in 0..<result.count {
            let expected = try pretokenizer.endOfPretoken(
              in: buffer,
              startingAt: scalarPosition
            )
            let entry = batchBuffer[index]
            let actual =
              entry.keyHigh == 0
              ? Int(entry.metadata)
              : entry.start + Int(entry.keyHigh >> 56)
            if actual != expected {
              Issue.record(
                "Boundary mismatch at input offset \(scalarPosition): expected \(expected), actual \(actual)"
              )
              return result
            }
            scalarPosition = expected
          }
          return result
        }
        position = result.endPosition
      }
    }
  }

}
