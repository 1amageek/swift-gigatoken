# swift-gigatoken

Pure Swift byte-level BPE tokenization for Native, WebAssembly, and Embedded Swift.

The current compatibility baseline is `r50k_base`. The package separates the Foundation-free tokenizer core from host model loading and benchmarking.

```swift
import Foundation
import SwiftGigaToken

var tokenizer = try GigaTokenizer(r50kModelAt: modelURL)
let tokens = try tokenizer.encodeOrdinary("Hello, world!")
let text = try tokenizer.decode(tokens)
```

## Build

```bash
swiftly run swift +6.3.1 ++ build
swiftly run swift +6.3.1 ++ build --swift-sdk swift-6.3.1-RELEASE_wasm --target SwiftGigaTokenCore
swiftly run swift +6.3.1 ++ build --swift-sdk swift-6.3.1-RELEASE_wasm-embedded --target SwiftGigaTokenCore
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm swift-gigatoken-smoke
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm-embedded swift-gigatoken-smoke
```

`SwiftGigaTokenCore` accepts rank-ordered token bytes directly, so Wasm and
Embedded Swift applications can embed model tables without Foundation, JSON,
Base64, filesystem APIs, or Rust. The `SwiftGigaToken` host target parses the
standard `.tiktoken` text format when Foundation is available.

## Low-level data path

The performance API borrows the input storage and writes directly into a
move-only, caller-owned token allocation:

```swift
import SwiftGigaTokenCore

var encoder = BPEEncoder(model: model)
var output = TokenBuffer(minimumCapacity: input.count / 3)

try input.withUnsafeBufferPointer { bytes throws(TokenizerError) in
  try encoder.encodeOrdinary(bytes, appendingTo: &output)
}
output.withUnsafeBufferPointer { tokens in
  consume(tokens)
}
```

This path does not materialize input slices or an intermediate token array.
`String`, `[TokenID]`, `bytes(for:)`, and `decode(_:)` are convenience/output
boundaries and intentionally materialize owned results. Use
`withTokenBytes(for:_:)`, borrowed buffer overloads, and `TokenBuffer` when the
caller needs scoped views and reusable storage.

For MLX Swift, Core AI, or another tensor runtime, depend on `TokenEncoding`
and consume the contiguous `UInt32` IDs without an intermediate array:

```swift
output.withUnsafeRawTokenIDs { tokenIDs in
  constructRuntimeInput(tokenIDs)
}
```

The pointer is valid only for the closure. Runtime-specific adapters and device
transfer are intentionally outside this package; the borrowed buffer and
ownership rules are the stable connection contract.

The r50k test fixture is OpenAI's public `r50k_base.tiktoken` model with
SHA-256 `306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930`.

See `Documentation/Architecture.md` for target boundaries and correctness
requirements, and `Documentation/Benchmark.md` for the reproducible Rust
comparison and measured results.
