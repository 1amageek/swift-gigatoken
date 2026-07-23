import Foundation
import GigaTokenCore

public protocol TiktokenModelLoading {
  func model(at url: URL) throws(TokenizerError) -> BPEModel
}
