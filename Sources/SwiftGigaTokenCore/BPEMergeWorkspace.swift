struct BPEMergeWorkspace: Sendable {
  private(set) var symbols: [UInt32] = []
  private var next: [Int] = []
  private var previous: [Int] = []
  private var ranks: [UInt32] = []

  init(minimumCapacity: Int = 64) {
    symbols.reserveCapacity(minimumCapacity)
    next.reserveCapacity(minimumCapacity)
    previous.reserveCapacity(minimumCapacity)
    ranks.reserveCapacity(minimumCapacity)
  }

  var symbolCount: Int {
    symbols.count
  }

  var symbolCapacity: Int {
    symbols.capacity
  }

  var linkCapacity: Int {
    min(next.capacity, previous.capacity, ranks.capacity)
  }

  mutating func encode(
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    byteTokenIDs: borrowing [UInt32],
    pairRanks: borrowing PairRankTable
  ) -> Int {
    symbols.removeAll(keepingCapacity: true)
    var position = range.lowerBound
    while position < range.upperBound {
      symbols.append(byteTokenIDs[Int(bytes[position])])
      position += 1
    }
    return merge(pairRanks: pairRanks)
  }

  mutating func encode(
    bytes: borrowing [UInt8],
    byteTokenIDs: borrowing [UInt32],
    pairRanks: borrowing PairRankTable
  ) -> Int {
    symbols.removeAll(keepingCapacity: true)
    var index = 0
    while index < bytes.count {
      symbols.append(byteTokenIDs[Int(bytes[index])])
      index += 1
    }
    return merge(pairRanks: pairRanks)
  }

  private mutating func merge(pairRanks: borrowing PairRankTable) -> Int {
    let count = symbols.count
    guard count > 1 else {
      return count
    }
    ensureAuxiliaryCapacity(count)

    var index = 0
    while index < count {
      next[index] = index + 1
      previous[index] = index - 1
      ranks[index] = UInt32.max
      index += 1
    }
    index = 0
    while index < count - 1 {
      ranks[index] = pairRanks.mergedTokenRaw(
        left: symbols[index],
        right: symbols[index + 1]
      )
      index += 1
    }

    while true {
      var bestRank = UInt32.max
      var bestIndex = 0
      index = 0
      while index < count - 1 {
        let rank = ranks[index]
        if rank < bestRank {
          bestRank = rank
          bestIndex = index
        }
        index += 1
      }
      guard bestRank != UInt32.max else {
        break
      }

      let dead = next[bestIndex]
      let newRight = next[dead]
      let left = previous[bestIndex]
      symbols[bestIndex] = bestRank
      next[bestIndex] = newRight
      ranks[dead] = UInt32.max
      if newRight < count {
        previous[newRight] = bestIndex
        ranks[bestIndex] = pairRanks.mergedTokenRaw(
          left: bestRank,
          right: symbols[newRight]
        )
      } else {
        ranks[bestIndex] = UInt32.max
      }
      if left >= 0 {
        ranks[left] = pairRanks.mergedTokenRaw(
          left: symbols[left],
          right: bestRank
        )
      }
    }

    var writeIndex = 0
    index = 0
    while index < count {
      symbols[writeIndex] = symbols[index]
      writeIndex += 1
      index = next[index]
    }
    symbols.removeLast(count - writeIndex)
    return writeIndex
  }

  private mutating func ensureAuxiliaryCapacity(_ capacity: Int) {
    guard next.count < capacity else {
      return
    }
    let additional = capacity - next.count
    next.append(contentsOf: repeatElement(0, count: additional))
    previous.append(contentsOf: repeatElement(0, count: additional))
    ranks.append(contentsOf: repeatElement(UInt32.max, count: additional))
  }
}
