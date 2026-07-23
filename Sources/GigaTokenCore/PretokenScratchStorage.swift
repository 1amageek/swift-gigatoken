struct PretokenScratchStorage: ~Copyable {
  static let batchCapacity = 272
  static let boundaryCapacity = 328

  let batchEntries: UnsafeMutablePointer<PretokenBatchEntry>
  let boundaries: UnsafeMutablePointer<UInt16>

  init() {
    batchEntries = .allocate(capacity: Self.batchCapacity)
    batchEntries.initialize(
      repeating: PretokenBatchEntry(),
      count: Self.batchCapacity
    )
    boundaries = .allocate(capacity: Self.boundaryCapacity)
    boundaries.initialize(repeating: 0, count: Self.boundaryCapacity)
  }

  deinit {
    boundaries.deinitialize(count: Self.boundaryCapacity)
    boundaries.deallocate()
    batchEntries.deinitialize(count: Self.batchCapacity)
    batchEntries.deallocate()
  }
}
