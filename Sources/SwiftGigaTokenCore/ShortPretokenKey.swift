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
    var value = low ^ high.rotatedRight(25)
    value &*= 0x9E37_79B9_7F4A_7C15
    return value ^ (value >> 32)
  }

  @_transparent
  private static func byteMask(count: Int) -> UInt64 {
    count == 8 ? UInt64.max : (UInt64(1) << UInt64(count * 8)) &- 1
  }
}

extension UInt64 {
  @inline(__always)
  fileprivate func rotatedRight(_ count: UInt64) -> UInt64 {
    (self >> count) | (self << (64 - count))
  }
}
