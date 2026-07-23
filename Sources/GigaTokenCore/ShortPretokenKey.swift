import VectorKernels
#if arch(arm64)
  import VectorKernelsNative
#endif

struct ShortPretokenKey: Equatable, Sendable {
  let low: UInt64
  let high: UInt64

  @_transparent
  init?(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>
  ) {
    self.init(bytes: bytes, start: range.lowerBound, count: range.upperBound - range.lowerBound)
  }

  @_transparent
  init?(
    bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    count: Int
  ) {
    guard count > 0, count <= 15 else {
      return nil
    }

    if bytes.count >= 16, start <= bytes.count &- 16, let baseAddress = bytes.baseAddress {
      let pointer = UnsafeRawPointer(baseAddress.advanced(by: start))
      let loadedLow = UInt64(littleEndian: pointer.loadUnaligned(as: UInt64.self))
      let loadedHigh = UInt64(
        littleEndian: pointer.advanced(by: 8).loadUnaligned(as: UInt64.self)
      )
      let lowCount = count < 8 ? count : 8
      let highCount = count > 8 ? count - 8 : 0
      low = loadedLow & Self.byteMask(count: lowCount)
      high = (loadedHigh & Self.byteMask(count: highCount)) | (UInt64(count) << 56)
      return
    }

    var packedLow: UInt64 = 0
    var packedHigh: UInt64 = UInt64(count) << 56
    var offset = 0
    while offset < min(count, 8) {
      packedLow |= UInt64(bytes[start + offset]) << UInt64(offset * 8)
      offset += 1
    }
    while offset < count {
      packedHigh |= UInt64(bytes[start + offset]) << UInt64((offset - 8) * 8)
      offset += 1
    }
    low = packedLow
    high = packedHigh
  }

  @_transparent
  init(low: UInt64, high: UInt64) {
    self.low = low
    self.high = high
  }

  @_transparent
  var hash: UInt64 {
    #if arch(arm64) && canImport(Darwin) && !hasFeature(Embedded)
      return ARMCRC32UInt64PairHashKernel.hash(low: low, high: high)
    #else
      #if arch(arm64)
        if ARMCRC32UInt64PairHashKernel.isAvailable {
          return ARMCRC32UInt64PairHashKernel.hash(low: low, high: high)
        }
      #endif
      return MultiplicativeUInt64PairHashKernel.hash(low: low, high: high)
    #endif
  }

  @_transparent
  private static func byteMask(count: Int) -> UInt64 {
    count == 8 ? UInt64.max : (UInt64(1) << UInt64(count * 8)) &- 1
  }
}
