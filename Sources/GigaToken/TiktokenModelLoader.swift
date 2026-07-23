import Foundation
import GigaTokenCore

public struct TiktokenModelLoader: TiktokenModelLoading, Sendable {
  private let addedTokens: [SpecialToken]

  public init(addedTokens: [SpecialToken] = []) {
    self.addedTokens = addedTokens
  }

  public static func r50kBase() -> Self {
    Self(addedTokens: [
      SpecialToken(bytes: Array("<|endoftext|>".utf8), id: TokenID(rawValue: 50_256))
    ])
  }

  public func model(at url: URL) throws(TokenizerError) -> BPEModel {
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw TokenizerError.unreadableModel(path: url.path)
    }
    return try data.withUnsafeBytes { rawBuffer throws(TokenizerError) in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      var tokenStorage: [UInt8] = []
      tokenStorage.reserveCapacity(max(256, data.count / 2))
      var tokenOffsets: [UInt32] = [0]
      tokenOffsets.reserveCapacity(64_000)
      var position = 0
      var lineNumber = 1
      while position < bytes.count {
        let lineStart = position
        while position < bytes.count, bytes[position] != 0x0A {
          position += 1
        }
        var lineEnd = position
        if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0D {
          lineEnd -= 1
        }
        if lineStart < lineEnd {
          try parseLine(
            bytes: bytes,
            range: lineStart..<lineEnd,
            lineNumber: lineNumber,
            tokenStorage: &tokenStorage,
            tokenOffsets: &tokenOffsets
          )
        }
        if position < bytes.count {
          position += 1
        }
        lineNumber += 1
      }
      return try BPEModel(
        packedTokenStorage: tokenStorage,
        tokenOffsets: tokenOffsets,
        specialTokens: addedTokens
      )
    }
  }

  private func parseLine(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    lineNumber: Int,
    tokenStorage: inout [UInt8],
    tokenOffsets: inout [UInt32]
  ) throws(TokenizerError) {
    var separator = range.lowerBound
    while separator < range.upperBound, bytes[separator] != 0x20 {
      separator += 1
    }
    guard separator < range.upperBound, separator + 1 < range.upperBound else {
      throw TokenizerError.invalidModelLine(line: lineNumber)
    }
    let rank = try parseRank(
      bytes: bytes,
      range: (separator + 1)..<range.upperBound,
      lineNumber: lineNumber
    )
    let expected = UInt32(tokenOffsets.count - 1)
    guard rank == expected else {
      throw TokenizerError.nonDenseRank(expected: expected, actual: rank, line: lineNumber)
    }
    try decodeBase64(
      bytes: bytes,
      range: range.lowerBound..<separator,
      lineNumber: lineNumber,
      output: &tokenStorage
    )
    guard UInt64(tokenStorage.count) <= UInt64(UInt32.max) else {
      throw TokenizerError.modelStorageTooLarge(byteCount: UInt64(tokenStorage.count))
    }
    tokenOffsets.append(UInt32(tokenStorage.count))
  }

  private func parseRank(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    lineNumber: Int
  ) throws(TokenizerError) -> UInt32 {
    var value: UInt32 = 0
    var position = range.lowerBound
    while position < range.upperBound {
      let byte = bytes[position]
      guard byte >= 0x30, byte <= 0x39 else {
        throw TokenizerError.invalidModelLine(line: lineNumber)
      }
      let digit = UInt32(byte - 0x30)
      guard value <= (UInt32.max - digit) / 10 else {
        throw TokenizerError.invalidModelLine(line: lineNumber)
      }
      value = value * 10 + digit
      position += 1
    }
    return value
  }

  private func decodeBase64(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    lineNumber: Int,
    output: inout [UInt8]
  ) throws(TokenizerError) {
    guard range.count % 4 == 0 else {
      throw TokenizerError.invalidBase64(line: lineNumber)
    }
    var position = range.lowerBound
    while position < range.upperBound {
      guard
        let first = base64Value(bytes[position]),
        let second = base64Value(bytes[position + 1])
      else {
        throw TokenizerError.invalidBase64(line: lineNumber)
      }
      let thirdByte = bytes[position + 2]
      let fourthByte = bytes[position + 3]
      let firstOutput = (first << 2) | (second >> 4)

      if thirdByte == 0x3D {
        guard fourthByte == 0x3D, second & 0x0F == 0, position + 4 == range.upperBound else {
          throw TokenizerError.invalidBase64(line: lineNumber)
        }
        output.append(firstOutput)
      } else {
        guard let third = base64Value(thirdByte) else {
          throw TokenizerError.invalidBase64(line: lineNumber)
        }
        let secondOutput = (second << 4) | (third >> 2)
        if fourthByte == 0x3D {
          guard third & 0x03 == 0, position + 4 == range.upperBound else {
            throw TokenizerError.invalidBase64(line: lineNumber)
          }
          output.append(firstOutput)
          output.append(secondOutput)
        } else {
          guard let fourth = base64Value(fourthByte) else {
            throw TokenizerError.invalidBase64(line: lineNumber)
          }
          output.append(firstOutput)
          output.append(secondOutput)
          output.append((third << 6) | fourth)
        }
      }
      position += 4
    }
  }

  @inline(__always)
  private func base64Value(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x41...0x5A:
      byte - 0x41
    case 0x61...0x7A:
      byte - 0x61 + 26
    case 0x30...0x39:
      byte - 0x30 + 52
    case 0x2B:
      62
    case 0x2F:
      63
    default:
      nil
    }
  }
}
