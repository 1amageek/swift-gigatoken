import Testing

@testable import SwiftGigaTokenCore

@Suite("Long pretoken cache")
struct LongPretokenCacheTests {
  @Test("Hash collisions compare every key byte")
  func hashCollision() {
    let first = Array("abcdefghijklmnop".utf8)
    let second = Array("abcdefghijklmnoq".utf8)
    let forcedHash: UInt64 = 0x1234_5678_9ABC_DEF0
    var cache = LongPretokenCache(minimumCapacity: 16)

    first.withUnsafeBufferPointer { bytes in
      cache.insert(
        bytes: bytes,
        range: 0..<bytes.count,
        hash: forcedHash,
        tokenOffset: 7,
        tokenCount: 3
      )
    }
    second.withUnsafeBufferPointer { bytes in
      #expect(cache.value(for: bytes, range: 0..<bytes.count, hash: forcedHash) == nil)
      cache.insert(
        bytes: bytes,
        range: 0..<bytes.count,
        hash: forcedHash,
        tokenOffset: 11,
        tokenCount: 5
      )
    }

    first.withUnsafeBufferPointer { bytes in
      let value = cache.value(for: bytes, range: 0..<bytes.count, hash: forcedHash)
      #expect(value?.tokenOffset == 7)
      #expect(value?.tokenCount == 3)
    }
    second.withUnsafeBufferPointer { bytes in
      let value = cache.value(for: bytes, range: 0..<bytes.count, hash: forcedHash)
      #expect(value?.tokenOffset == 11)
      #expect(value?.tokenCount == 5)
    }
    #expect(cache.entryCount == 2)
    #expect(cache.storedByteCount == first.count + second.count)
  }

  @Test("Growth preserves owned keys and token ranges")
  func growth() {
    var cache = LongPretokenCache(minimumCapacity: 16)
    var keys: [[UInt8]] = []
    for index in 0..<24 {
      let key = Array("long-pretoken-key-\(index)-payload".utf8)
      keys.append(key)
      key.withUnsafeBufferPointer { bytes in
        let hash = LongPretokenCache.hash(bytes: bytes, range: 0..<bytes.count)
        cache.insert(
          bytes: bytes,
          range: 0..<bytes.count,
          hash: hash,
          tokenOffset: index * 3,
          tokenCount: index + 1
        )
      }
    }

    for (index, key) in keys.enumerated() {
      key.withUnsafeBufferPointer { bytes in
        let hash = LongPretokenCache.hash(bytes: bytes, range: 0..<bytes.count)
        let value = cache.value(for: bytes, range: 0..<bytes.count, hash: hash)
        #expect(value?.tokenOffset == index * 3)
        #expect(value?.tokenCount == index + 1)
      }
    }
    #expect(cache.entryCount == keys.count)
    #expect(cache.slotCapacity >= 64)
  }
}
