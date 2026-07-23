/// Distinguishes token lookup failures from failures produced by a scoped byte consumer.
public enum TokenByteAccessError<Failure: Error>: Error {
  case tokenizer(TokenizerError)
  case consumer(Failure)
}
