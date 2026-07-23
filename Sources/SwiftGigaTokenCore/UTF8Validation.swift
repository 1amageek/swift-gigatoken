public enum UTF8Validation {
  @inlinable
  public static func firstInvalidOffset(
    in bytes: UnsafeBufferPointer<UInt8>
  ) -> Int? {
    var index = 0
    while index < bytes.count {
      let first = bytes[index]
      if first < 0x80 {
        index += 1
        continue
      }

      if first >= 0xC2, first <= 0xDF {
        guard index + 1 < bytes.count, isContinuation(bytes[index + 1]) else {
          return index
        }
        index += 2
        continue
      }

      if first >= 0xE0, first <= 0xEF {
        guard index + 2 < bytes.count else {
          return index
        }
        let second = bytes[index + 1]
        let third = bytes[index + 2]
        let validSecond =
          if first == 0xE0 {
            second >= 0xA0 && second <= 0xBF
          } else if first == 0xED {
            second >= 0x80 && second <= 0x9F
          } else {
            isContinuation(second)
          }
        guard validSecond, isContinuation(third) else {
          return index
        }
        index += 3
        continue
      }

      if first >= 0xF0, first <= 0xF4 {
        guard index + 3 < bytes.count else {
          return index
        }
        let second = bytes[index + 1]
        let validSecond =
          if first == 0xF0 {
            second >= 0x90 && second <= 0xBF
          } else if first == 0xF4 {
            second >= 0x80 && second <= 0x8F
          } else {
            isContinuation(second)
          }
        guard
          validSecond,
          isContinuation(bytes[index + 2]),
          isContinuation(bytes[index + 3])
        else {
          return index
        }
        index += 4
        continue
      }

      return index
    }
    return nil
  }

  @inlinable
  static func isContinuation(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
  }
}
