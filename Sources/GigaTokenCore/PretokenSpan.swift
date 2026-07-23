public struct PretokenSpan: Equatable, Sendable {
  public let range: Range<Int>

  public init(range: Range<Int>) {
    self.range = range
  }
}
