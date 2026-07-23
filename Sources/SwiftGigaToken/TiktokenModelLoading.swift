import Foundation
import SwiftGigaTokenCore

public protocol TiktokenModelLoading {
  func model(at url: URL) throws(TokenizerError) -> BPEModel
}
