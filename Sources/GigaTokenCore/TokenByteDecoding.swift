/// A decoder that exposes scoped token bytes without materializing a copy.
public protocol TokenByteDecoding: ~Copyable {
  func withTokenBytes<Result, Failure: Error>(
    for token: TokenID,
    _ body: (UnsafeBufferPointer<UInt8>) throws(Failure) -> Result
  ) throws(TokenByteAccessError<Failure>) -> Result

  /// Appends decoded bytes atomically. The output is unchanged if decoding fails.
  func decode(
    _ tokens: UnsafeBufferPointer<TokenID>,
    appendingTo output: inout [UInt8]
  ) throws(TokenizerError)
}
