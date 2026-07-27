import VectorKernels

public struct R50KPretokenizer: Sendable {
  #if arch(arm64) && canImport(Darwin) && !hasFeature(Embedded)
    private let byteMaskKernel: SIMD128ByteMaskKernel
  #else
    private let byteMaskKernel: SWARByteMaskKernel
  #endif
  private let setBitPositions: SetBitPositions64

  public init() {
    #if arch(arm64) && canImport(Darwin) && !hasFeature(Embedded)
      byteMaskKernel = SIMD128ByteMaskKernel()
    #else
      byteMaskKernel = SWARByteMaskKernel()
    #endif
    setBitPositions = SetBitPositions64()
  }

  @inline(never)
  func fillPretokenBatch(
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int,
    into batch: UnsafeMutablePointer<PretokenBatchEntry>,
    boundaries boundaryBaseAddress: UnsafeMutablePointer<UInt16>,
    prefetchCache: borrowing ShortPretokenCache
  ) throws(TokenizerError) -> PretokenBatchFillResult {
    var pending = start
    var scan = start
    var boundaryCount = 0

    harvest: while boundaryCount < 256, pending < bytes.count {
      if scan - start > Int(UInt16.max) - 127 {
        if boundaryCount == 0 {
          let end = try endOfPretoken(in: bytes, startingAt: start)
          storePretoken(
            bytes: bytes,
            start: start,
            end: end,
            at: 0,
            in: batch,
            prefetchCache: prefetchCache
          )
          return PretokenBatchFillResult(count: 1, endPosition: end)
        }
        break
      }

      guard bytes.count - scan >= 70 else {
        let end = try endOfPretoken(in: bytes, startingAt: pending)
        let relativeEnd = end - start
        if relativeEnd > Int(UInt16.max) {
          if boundaryCount == 0 {
            storePretoken(
              bytes: bytes,
              start: start,
              end: end,
              at: 0,
              in: batch,
              prefetchCache: prefetchCache
            )
            return PretokenBatchFillResult(count: 1, endPosition: end)
          }
          break
        }
        boundaryBaseAddress[boundaryCount] = UInt16(relativeEnd)
        boundaryCount += 1
        pending = end
        scan = pending
        continue
      }

      if pending >= scan + 64 {
        scan += ((pending - scan) / 64) * 64
      }

      let boundary = try boundaryMask(in: bytes, scan: scan, pending: pending)

      guard let boundary else {
        let scalarLimit = scan + 64
        repeat {
          let end = try endOfPretoken(in: bytes, startingAt: pending)
          let relativeEnd = end - start
          if relativeEnd > Int(UInt16.max) {
            if boundaryCount == 0 {
              storePretoken(
                bytes: bytes,
                start: start,
                end: end,
                at: 0,
                in: batch,
                prefetchCache: prefetchCache
              )
              return PretokenBatchFillResult(count: 1, endPosition: end)
            }
            break harvest
          }
          boundaryBaseAddress[boundaryCount] = UInt16(relativeEnd)
          boundaryCount += 1
          pending = end
        } while boundaryCount < 256 && pending < scalarLimit
        scan = pending
        continue
      }

      let relativePending = pending - scan
      var candidates = boundary
      if relativePending >= 0 {
        if relativePending >= 63 {
          candidates = 0
        } else {
          candidates &= UInt64.max &<< (relativePending + 1)
        }
      }
      let appended = unsafe setBitPositions.write(
        mask: candidates,
        relativeOffset: UInt16(scan - start),
        to: boundaryBaseAddress.advanced(by: boundaryCount)
      )
      boundaryCount += appended
      if boundaryCount > 0 {
        pending = start + Int(boundaryBaseAddress[boundaryCount - 1])
      }
      scan += 64
    }

    let emitCount = boundaryCount < 256 ? boundaryCount : 256
    var previous = start
    var index = 0
    while index &+ 1 < emitCount {
      let firstEnd = start &+ Int(boundaryBaseAddress[index])
      let secondEnd = start &+ Int(boundaryBaseAddress[index &+ 1])
      storePretoken(
        bytes: bytes,
        start: previous,
        end: firstEnd,
        at: index,
        in: batch,
        prefetchCache: prefetchCache
      )
      storePretoken(
        bytes: bytes,
        start: firstEnd,
        end: secondEnd,
        at: index &+ 1,
        in: batch,
        prefetchCache: prefetchCache
      )
      previous = secondEnd
      index &+= 2
    }
    while index < emitCount {
      let end = start &+ Int(boundaryBaseAddress[index])
      storePretoken(
        bytes: bytes,
        start: previous,
        end: end,
        at: index,
        in: batch,
        prefetchCache: prefetchCache
      )
      previous = end
      index &+= 1
    }
    return PretokenBatchFillResult(count: emitCount, endPosition: previous)
  }

  @inline(never)
  private func boundaryMask(
    in bytes: UnsafeBufferPointer<UInt8>,
    scan: Int,
    pending: Int
  ) throws(TokenizerError) -> UInt64? {
    let baseAddress = bytes.baseAddress!
    let hasASCIIPreviousCarry =
      scan == pending || scan == 0 || baseAddress.advanced(by: scan - 1).pointee < 0x80
    return try unsafe byteMaskKernel.withASCIICharacterMasks64(
      unchecked: UnsafeRawPointer(baseAddress.advanced(by: scan))
    ) {
      ascii,
      asciiLetter,
      asciiDigit,
      asciiWhitespace,
      asciiSpace,
      asciiApostrophe throws(TokenizerError) -> UInt64? in
      if ascii == UInt64.max,
        baseAddress.advanced(by: scan + 64).pointee < 0x80,
        hasASCIIPreviousCarry
      {
        return asciiBoundaryMask(
          bytes: baseAddress,
          scan: scan,
          asciiLetter: asciiLetter,
          asciiDigit: asciiDigit,
          asciiWhitespace: asciiWhitespace,
          asciiSpace: asciiSpace,
          asciiApostrophe: asciiApostrophe,
          scanStartsAtTokenBoundary: scan == pending
        )
      }
      return try unicodeBoundaryMask(
        in: bytes,
        scan: scan,
        ascii: ascii,
        asciiLetter: asciiLetter,
        asciiDigit: asciiDigit,
        asciiWhitespace: asciiWhitespace,
        asciiSpace: asciiSpace,
        asciiApostrophe: asciiApostrophe,
        scanStartsAtTokenBoundary: scan == pending
      )
    }
  }

  @inline(never)
  private func unicodeBoundaryMask(
    in bytes: UnsafeBufferPointer<UInt8>,
    scan: Int,
    ascii: UInt64,
    asciiLetter: UInt64,
    asciiDigit: UInt64,
    asciiWhitespace: UInt64,
    asciiSpace: UInt64,
    asciiApostrophe: UInt64,
    scanStartsAtTokenBoundary: Bool
  ) throws(TokenizerError) -> UInt64? {
    let blockEnd = scan + 64
    var letters = asciiLetter
    var digits = asciiDigit
    var whitespace = asciiWhitespace
    var other = ~(asciiLetter | asciiDigit | asciiWhitespace) & ascii
    var continuation: UInt64 = 0
    var whitespaceLeads = asciiWhitespace
    var splitWhitespace: UInt64 = 0

    var previousLetter: UInt64 = 0
    var previousDigit: UInt64 = 0
    var previousSpace: UInt64 = 0
    var previousWhitespace: UInt64 = 0
    var previousOther: UInt64 = 0
    var position = scan

    if !scanStartsAtTokenBoundary, scan > 0 {
      let previousByte = bytes[scan - 1]
      if previousByte < 0x80 {
        let isLetter = Self.isASCIILetter(previousByte)
        let isDigit = Self.isASCIIDigit(previousByte)
        let isWhitespace = Self.isASCIIWhitespace(previousByte)
        previousLetter = isLetter ? 1 : 0
        previousDigit = isDigit ? 1 : 0
        previousSpace = previousByte == 0x20 ? 1 : 0
        previousWhitespace = isWhitespace ? 1 : 0
        previousOther = !isLetter && !isDigit && !isWhitespace ? 1 : 0
      } else {
        var lead = scan - 1
        while lead > 0, bytes[lead] & 0xC0 == 0x80, scan - lead < 4 {
          lead -= 1
        }
        let decoded = try Self.decodeScalar(in: bytes, at: lead)
        guard decoded.end >= scan else {
          throw TokenizerError.invalidUTF8(offset: lead)
        }
        let characterClass = Self.classify(decoded.scalar)
        switch characterClass {
        case .letter: previousLetter = 1
        case .number: previousDigit = 1
        case .whitespace: previousWhitespace = 1
        case .other: previousOther = 1
        }
        if decoded.end > scan {
          guard characterClass != .whitespace else {
            return nil
          }
          let claimedCount = min(decoded.end, blockEnd) - scan
          let claimed = Self.lowBitMask(count: claimedCount)
          continuation |= claimed
          switch characterClass {
          case .letter: letters |= claimed
          case .number: digits |= claimed
          case .whitespace: whitespace |= claimed
          case .other: other |= claimed
          }
          position = decoded.end
        }
      }
    } else if scanStartsAtTokenBoundary, bytes[scan] & 0xC0 == 0x80 {
      throw TokenizerError.invalidUTF8(offset: scan)
    }

    while position < blockEnd {
      let byte = bytes[position]
      if byte < 0x80 {
        position += 1
        continue
      }
      let decoded = try Self.decodeScalar(in: bytes, at: position)
      let end = min(decoded.end, blockEnd)
      let relativeStart = position - scan
      let byteCount = end - position
      let characterMask = Self.lowBitMask(count: byteCount) &<< UInt64(relativeStart)
      let lead = UInt64(1) &<< UInt64(relativeStart)
      continuation |= characterMask & ~lead
      let characterClass = Self.classify(decoded.scalar)
      switch characterClass {
      case .letter:
        letters |= characterMask
      case .number:
        digits |= characterMask
      case .whitespace:
        guard decoded.end <= blockEnd else {
          return nil
        }
        whitespace |= characterMask
        whitespaceLeads |= lead
        if try Self.characterClass(in: bytes, at: decoded.end) != .whitespace {
          splitWhitespace |= lead
        }
      case .other:
        other |= characterMask
      }
      position = decoded.end
    }

    var asciiSplit = asciiWhitespace & (~whitespace &>> 1)
    if asciiWhitespace & (UInt64(1) &<< 63) != 0 {
      if try Self.characterClass(in: bytes, at: blockEnd) != .whitespace {
        asciiSplit |= UInt64(1) &<< 63
      }
    }
    splitWhitespace |= asciiSplit

    let continuingSameClass =
      (letters & ((letters &<< 1) | previousLetter))
      | (digits & ((digits &<< 1) | previousDigit))
      | (other & ((other &<< 1) | previousOther))
    let followsSpace = (asciiSpace &<< 1) | previousSpace
    let nonWhitespaceBoundary =
      ~whitespace & ~continuingSameClass & ~followsSpace & ~continuation
    let previousWhitespaceBits = (whitespace &<< 1) | previousWhitespace
    let whitespaceBoundary = whitespaceLeads & (~previousWhitespaceBits | splitWhitespace)
    var boundary = nonWhitespaceBoundary | whitespaceBoundary

    var contractionCandidates = asciiApostrophe & boundary
    while contractionCandidates != 0 {
      let index = contractionCandidates.trailingZeroBitCount
      contractionCandidates &= contractionCandidates &- 1
      guard index < 61 else {
        return nil
      }
      let suffixLength: Int
      switch bytes[scan + index + 1] {
      case 0x73, 0x64, 0x6D, 0x74:
        suffixLength = 2
      case 0x6C where bytes[scan + index + 2] == 0x6C:
        suffixLength = 3
      case 0x76 where bytes[scan + index + 2] == 0x65:
        suffixLength = 3
      case 0x72 where bytes[scan + index + 2] == 0x65:
        suffixLength = 3
      default:
        suffixLength = 0
      }
      if suffixLength != 0 {
        boundary &= ~(UInt64(1) &<< UInt64(index + 1))
        boundary |= UInt64(1) &<< UInt64(index + suffixLength)
      }
    }
    return boundary
  }

  @_transparent
  private func storePretoken(
    bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int,
    at index: Int,
    in batch: UnsafeMutablePointer<PretokenBatchEntry>,
    prefetchCache: borrowing ShortPretokenCache
  ) {
    if let key = ShortPretokenKey(bytes: bytes, start: start, count: end &- start) {
      let hash = key.hash
      batch.advanced(by: index).pointee = PretokenBatchEntry(
        start: start,
        metadata: hash,
        keyLow: key.low,
        keyHigh: key.high
      )
      prefetchCache.prefetchForRead(hash: hash, locality: .level2)
      return
    }
    batch.advanced(by: index).pointee = PretokenBatchEntry(
      start: start,
      metadata: UInt64(end),
      keyLow: 0,
      keyHigh: 0
    )
  }

  @inline(__always)
  private func asciiBoundaryMask(
    bytes: UnsafePointer<UInt8>,
    scan: Int,
    asciiLetter: UInt64,
    asciiDigit: UInt64,
    asciiWhitespace: UInt64,
    asciiSpace: UInt64,
    asciiApostrophe: UInt64,
    scanStartsAtTokenBoundary: Bool
  ) -> UInt64? {
    let space = asciiSpace
    let apostrophe = asciiApostrophe
    let letters = asciiLetter
    let digits = asciiDigit
    let whitespace = asciiWhitespace
    let other = ~(letters | digits | whitespace)

    let previousLetter: UInt64
    let previousDigit: UInt64
    let previousSpace: UInt64
    let previousWhitespace: UInt64
    let previousOther: UInt64
    if scanStartsAtTokenBoundary {
      (previousLetter, previousDigit, previousSpace, previousWhitespace, previousOther) =
        (0, 0, 0, 0, 0)
    } else {
      let previous = bytes.advanced(by: scan - 1).pointee
      let isLetter = Self.isASCIILetter(previous)
      let isDigit = Self.isASCIIDigit(previous)
      let isWhitespace = Self.isASCIIWhitespace(previous)
      previousLetter = isLetter ? 1 : 0
      previousDigit = isDigit ? 1 : 0
      previousSpace = previous == 0x20 ? 1 : 0
      previousWhitespace = isWhitespace ? 1 : 0
      previousOther = !isLetter && !isDigit && !isWhitespace ? 1 : 0
    }

    let continuingSameClass =
      (letters & ((letters &<< 1) | previousLetter))
      | (digits & ((digits &<< 1) | previousDigit))
      | (other & ((other &<< 1) | previousOther))
    let followsSpace = (space &<< 1) | previousSpace
    let nonWhitespaceBoundary = ~whitespace & ~continuingSameClass & ~followsSpace

    var splitWhitespace = whitespace & (~whitespace &>> 1)
    if !Self.isASCIIWhitespace(bytes.advanced(by: scan + 64).pointee) {
      splitWhitespace |= (UInt64(1) &<< 63) & whitespace
    }
    let previousWhitespaceBits = (whitespace &<< 1) | previousWhitespace
    let whitespaceBoundary = whitespace & (~previousWhitespaceBits | splitWhitespace)
    var boundary = nonWhitespaceBoundary | whitespaceBoundary

    var contractionCandidates = apostrophe & boundary
    while contractionCandidates != 0 {
      let index = contractionCandidates.trailingZeroBitCount
      contractionCandidates &= contractionCandidates &- 1
      guard index < 61 else {
        return nil
      }
      let suffixLength: Int
      switch bytes.advanced(by: scan + index + 1).pointee {
      case 0x73, 0x64, 0x6D, 0x74:
        suffixLength = 2
      case 0x6C where bytes.advanced(by: scan + index + 2).pointee == 0x6C:
        suffixLength = 3
      case 0x76 where bytes.advanced(by: scan + index + 2).pointee == 0x65:
        suffixLength = 3
      case 0x72 where bytes.advanced(by: scan + index + 2).pointee == 0x65:
        suffixLength = 3
      default:
        suffixLength = 0
      }
      if suffixLength != 0 {
        boundary &= ~(UInt64(1) &<< (index + 1))
        boundary |= UInt64(1) &<< (index + suffixLength)
      }
    }
    return boundary
  }

  public func spans(in bytes: [UInt8]) throws(TokenizerError) -> [PretokenSpan] {
    try bytes.withUnsafeBufferPointer { buffer throws(TokenizerError) in
      try spans(in: buffer)
    }
  }

  public func spans(
    in bytes: UnsafeBufferPointer<UInt8>
  ) throws(TokenizerError) -> [PretokenSpan] {
    var result: [PretokenSpan] = []
    var position = 0
    while position < bytes.count {
      let end = try endOfPretoken(in: bytes, startingAt: position)
      result.append(PretokenSpan(range: position..<end))
      position = end
    }
    return result
  }

  @inline(__always)
  func endOfPretoken(
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
  ) throws(TokenizerError) -> Int {
    let baseAddress = bytes.baseAddress!
    let first = baseAddress[start]
    if Self.isASCIILetter(first) {
      return try scanRun(in: bytes, from: start + 1, matching: .letter)
    }
    if first == 0x20 {
      guard start + 1 < bytes.count else {
        return start + 1
      }
      let next = baseAddress[start + 1]
      if Self.isASCIILetter(next) {
        return try scanRun(in: bytes, from: start + 2, matching: .letter)
      }
      if Self.isASCIIDigit(next) {
        return try scanRun(in: bytes, from: start + 2, matching: .number)
      }
      if next >= 0x80 {
        let decoded = try Self.decodeScalar(in: bytes, at: start + 1)
        switch Self.classify(decoded.scalar) {
        case .letter:
          return try scanRun(in: bytes, from: decoded.end, matching: .letter)
        case .number:
          return try scanRun(in: bytes, from: decoded.end, matching: .number)
        case .whitespace:
          return try scanWhitespace(in: bytes, from: start, tokenStart: start)
        case .other:
          return try scanRun(in: bytes, from: decoded.end, matching: .other)
        }
      }
      if Self.isASCIIWhitespace(next) {
        return try scanWhitespace(in: bytes, from: start, tokenStart: start)
      }
      return try scanRun(in: bytes, from: start + 2, matching: .other)
    }
    if first >= 0x80 {
      let decoded = try Self.decodeScalar(in: bytes, at: start)
      let characterClass = Self.classify(decoded.scalar)
      switch characterClass {
      case .letter, .number, .other:
        return try scanRun(in: bytes, from: decoded.end, matching: characterClass)
      case .whitespace:
        return try scanWhitespace(in: bytes, from: start, tokenStart: start)
      }
    }
    if Self.isASCIIDigit(first) {
      return try scanRun(in: bytes, from: start + 1, matching: .number)
    }
    if first == 0x27 {
      if start + 1 < bytes.count {
        switch baseAddress[start + 1] {
        case 0x73, 0x64, 0x6D, 0x74:
          return start + 2
        case 0x6C where start + 2 < bytes.count && baseAddress[start + 2] == 0x6C:
          return start + 3
        case 0x76 where start + 2 < bytes.count && baseAddress[start + 2] == 0x65:
          return start + 3
        case 0x72 where start + 2 < bytes.count && baseAddress[start + 2] == 0x65:
          return start + 3
        default:
          break
        }
      }
      return try scanRun(in: bytes, from: start + 1, matching: .other)
    }
    if Self.isASCIIWhitespace(first) {
      return try scanWhitespace(in: bytes, from: start, tokenStart: start)
    }
    return try scanRun(in: bytes, from: start + 1, matching: .other)
  }

  @inline(__always)
  private func scanRun(
    in bytes: UnsafeBufferPointer<UInt8>,
    from start: Int,
    matching expected: CharacterClass
  ) throws(TokenizerError) -> Int {
    if expected == .letter {
      return try scanLetterRun(in: bytes, from: start)
    }
    let baseAddress = bytes.baseAddress!
    var position = start
    while position < bytes.count {
      let byte = baseAddress[position]
      if byte < 0x80 {
        let characterClass = Self.classifyASCII(byte)
        guard characterClass == expected else {
          return position
        }
        position += 1
      } else {
        let decoded = try Self.decodeScalar(in: bytes, at: position)
        guard Self.classify(decoded.scalar) == expected else {
          return position
        }
        position = decoded.end
      }
    }
    return position
  }

  @inline(__always)
  private func scanLetterRun(
    in bytes: UnsafeBufferPointer<UInt8>,
    from start: Int
  ) throws(TokenizerError) -> Int {
    let baseAddress = bytes.baseAddress!
    var position = start
    while true {
      position = Self.scanASCIILetters(in: bytes, from: position)
      guard position < bytes.count, baseAddress[position] >= 0x80 else {
        return position
      }
      let decoded = try Self.decodeScalar(in: bytes, at: position)
      guard Self.classify(decoded.scalar) == .letter else {
        return position
      }
      position = decoded.end
    }
  }

  @inline(__always)
  private static func scanASCIILetters(
    in bytes: UnsafeBufferPointer<UInt8>,
    from start: Int
  ) -> Int {
    let highBits: UInt64 = 0x8080_8080_8080_8080
    var position = start
    let baseAddress = bytes.baseAddress!
    while position + 8 <= bytes.count {
      let word = UInt64(
        littleEndian: UnsafeRawPointer(baseAddress.advanced(by: position))
          .loadUnaligned(as: UInt64.self)
      )
      if word & highBits != 0 {
        break
      }
      let lowered = word | 0x2020_2020_2020_2020
      let greaterThanOrEqualA = (lowered | highBits) &- 0x6161_6161_6161_6161
      let lessThanOrEqualZ = 0xFAFA_FAFA_FAFA_FAFA &- lowered
      let nonLetter = ~(greaterThanOrEqualA & lessThanOrEqualZ) & highBits
      if nonLetter != 0 {
        return position + nonLetter.trailingZeroBitCount / 8
      }
      position += 8
    }
    while position < bytes.count, Self.isASCIILetter(baseAddress[position]) {
      position += 1
    }
    return position
  }

  @inline(__always)
  private func scanWhitespace(
    in bytes: UnsafeBufferPointer<UInt8>,
    from start: Int,
    tokenStart: Int
  ) throws(TokenizerError) -> Int {
    let baseAddress = bytes.baseAddress!
    var position = start
    var lastScalarStart = tokenStart
    while position < bytes.count {
      let byte = baseAddress[position]
      if byte < 0x80 {
        guard Self.isASCIIWhitespace(byte) else {
          break
        }
        lastScalarStart = position
        position += 1
      } else {
        let decoded = try Self.decodeScalar(in: bytes, at: position)
        guard Self.classify(decoded.scalar) == .whitespace else {
          break
        }
        lastScalarStart = position
        position = decoded.end
      }
    }
    if position < bytes.count && lastScalarStart > tokenStart {
      return lastScalarStart
    }
    return position
  }

  @inline(__always)
  private static func classifyASCII(_ byte: UInt8) -> CharacterClass {
    if isASCIILetter(byte) {
      return .letter
    }
    if isASCIIDigit(byte) {
      return .number
    }
    if isASCIIWhitespace(byte) {
      return .whitespace
    }
    return .other
  }

  @inline(__always)
  private static func classify(_ scalar: UInt32) -> CharacterClass {
    UnicodeClassTable.classify(scalar)
  }

  @inline(__always)
  private static func characterClass(
    in bytes: UnsafeBufferPointer<UInt8>,
    at position: Int
  ) throws(TokenizerError) -> CharacterClass {
    let byte = bytes[position]
    if byte < 0x80 {
      return classifyASCII(byte)
    }
    return classify(try decodeScalar(in: bytes, at: position).scalar)
  }

  @inline(__always)
  private static func decodeScalar(
    in bytes: UnsafeBufferPointer<UInt8>,
    at position: Int
  ) throws(TokenizerError) -> DecodedScalar {
    let baseAddress = bytes.baseAddress!
    let first = baseAddress[position]
    let length: Int
    let initial: UInt32
    switch first {
    case 0xC2...0xDF:
      length = 2
      initial = UInt32(first & 0x1F)
    case 0xE0...0xEF:
      length = 3
      initial = UInt32(first & 0x0F)
    case 0xF0...0xF4:
      length = 4
      initial = UInt32(first & 0x07)
    default:
      throw TokenizerError.invalidUTF8(offset: position)
    }
    guard position + length <= bytes.count else {
      throw TokenizerError.invalidUTF8(offset: position)
    }
    let second = baseAddress[position + 1]
    guard second & 0xC0 == 0x80 else {
      throw TokenizerError.invalidUTF8(offset: position)
    }
    switch first {
    case 0xE0 where second < 0xA0,
      0xED where second > 0x9F,
      0xF0 where second < 0x90,
      0xF4 where second > 0x8F:
      throw TokenizerError.invalidUTF8(offset: position)
    default:
      break
    }
    var value = initial
    for index in (position + 1)..<(position + length) {
      let continuation = baseAddress[index]
      guard continuation & 0xC0 == 0x80 else {
        throw TokenizerError.invalidUTF8(offset: position)
      }
      value = (value << 6) | UInt32(continuation & 0x3F)
    }
    guard value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else {
      throw TokenizerError.invalidUTF8(offset: position)
    }
    return DecodedScalar(scalar: value, end: position + length)
  }

  @_transparent
  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (byte | 0x20) &- 0x61 < 26
  }

  @_transparent
  private static func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte &- 0x30 < 10
  }

  @_transparent
  private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte &- 9 < 5
  }

  @_transparent
  private static func lowBitMask(count: Int) -> UInt64 {
    count == 64 ? UInt64.max : (UInt64(1) &<< UInt64(count)) &- 1
  }
}

enum CharacterClass: Equatable {
  case letter
  case number
  case whitespace
  case other
}

private struct DecodedScalar {
  let scalar: UInt32
  let end: Int
}
