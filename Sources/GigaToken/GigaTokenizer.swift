import Foundation
import GigaTokenCore

public struct GigaTokenizer: ~Copyable, TokenEncoding, TokenByteDecoding {
  public let model: BPEModel
  private var encoder: BPEEncoder

  public init(model: BPEModel) {
    self.model = model
    encoder = BPEEncoder(model: model)
  }

  public init(r50kModelAt url: URL) throws(TokenizerError) {
    try self.init(model: TiktokenModelLoader.r50kBase().model(at: url))
  }

  public var storageMetrics: EncodingStorageMetrics {
    encoder.storageMetrics
  }

  public mutating func encodeOrdinary(_ bytes: [UInt8]) throws(TokenizerError) -> [TokenID] {
    try encoder.encodeOrdinary(bytes)
  }

  public mutating func encodeOrdinary(
    _ bytes: [UInt8],
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError) {
    try encoder.encodeOrdinary(bytes, appendingTo: &output)
  }

  public mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout [TokenID]
  ) throws(TokenizerError) {
    try encoder.encodeOrdinary(bytes, appendingTo: &output)
  }

  public mutating func encodeOrdinary(
    _ bytes: UnsafeBufferPointer<UInt8>,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError) {
    try encoder.encodeOrdinary(bytes, appendingTo: &output)
  }

  public mutating func encodeOrdinary(_ text: String) throws(TokenizerError) -> [TokenID] {
    try encoder.encodeOrdinary(text)
  }

  public mutating func encode(
    _ bytes: [UInt8],
    specialTokenPolicy: SpecialTokenPolicy = .disallow
  ) throws(TokenizerError) -> [TokenID] {
    try encoder.encode(bytes, specialTokenPolicy: specialTokenPolicy)
  }

  public mutating func encode(
    _ text: String,
    specialTokenPolicy: SpecialTokenPolicy = .disallow
  ) throws(TokenizerError) -> [TokenID] {
    try encoder.encode(text, specialTokenPolicy: specialTokenPolicy)
  }

  public mutating func encode(
    _ bytes: UnsafeBufferPointer<UInt8>,
    specialTokenPolicy: SpecialTokenPolicy = .disallow,
    appendingTo output: inout TokenBuffer
  ) throws(TokenizerError) {
    try encoder.encode(
      bytes,
      specialTokenPolicy: specialTokenPolicy,
      appendingTo: &output
    )
  }

  public func decodeBytes(_ tokens: [TokenID]) throws(TokenizerError) -> [UInt8] {
    try model.decode(tokens)
  }

  public func withTokenBytes<Result, Failure: Error>(
    for token: TokenID,
    _ body: (UnsafeBufferPointer<UInt8>) throws(Failure) -> Result
  ) throws(TokenByteAccessError<Failure>) -> Result {
    try model.withTokenBytes(for: token, body)
  }

  public func decode(
    _ tokens: UnsafeBufferPointer<TokenID>,
    appendingTo output: inout [UInt8]
  ) throws(TokenizerError) {
    try model.decode(tokens, appendingTo: &output)
  }

  public func decode(_ tokens: [TokenID]) throws(TokenizerError) -> String {
    let bytes = try decodeBytes(tokens)
    if let invalidOffset = bytes.withUnsafeBufferPointer(UTF8Validation.firstInvalidOffset) {
      throw TokenizerError.invalidUTF8(offset: invalidOffset)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
