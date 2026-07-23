struct PretokenBatchEntry: Sendable {
  var start: Int = 0
  var metadata: UInt64 = 0
  var keyLow: UInt64 = 0
  var keyHigh: UInt64 = 0
}

struct PretokenBatchFillResult: Sendable {
  let count: Int
  let endPosition: Int
}
