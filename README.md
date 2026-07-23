# swift-gigatoken

Byte-level BPE tokenization with a Pure Swift portable data path for Native,
WebAssembly, and Embedded Swift, plus compile-time-gated native kernels where
the target contract guarantees the required instructions.

## Acknowledgements

This project is an independent Swift implementation inspired by
[`gigatoken`](https://github.com/marcelroed/gigatoken), created by
[Marcel Roed](https://github.com/marcelroed). The original project established
the `gigatoken` name and demonstrated high-throughput language-model
tokenization. `swift-gigatoken` exists because of that work, and references to
this implementation's lineage should credit the original project and author.

The current compatibility baseline is `r50k_base`. The package separates the Foundation-free tokenizer core from host model loading and benchmarking.

```swift
import Foundation
import GigaToken

var tokenizer = try GigaTokenizer(r50kModelAt: modelURL)
let tokens = try tokenizer.encodeOrdinary("Hello, world!")
let text = try tokenizer.decode(tokens)
```

## Build

```bash
swiftly run swift +6.3.1 ++ build
swiftly run swift +6.3.1 ++ build --swift-sdk swift-6.3.1-RELEASE_wasm --target GigaTokenCore
swiftly run swift +6.3.1 ++ build --swift-sdk swift-6.3.1-RELEASE_wasm-embedded --target GigaTokenCore
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm gigatoken-smoke
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm-embedded gigatoken-smoke
```

`GigaTokenCore` accepts rank-ordered token bytes directly, so Wasm and
Embedded Swift applications can embed model tables without Foundation, JSON,
Base64, filesystem APIs, or Rust. The `GigaToken` host target parses the
standard `.tiktoken` text format when Foundation is available.

The tokenizer's public API, storage ownership, BPE logic, and portable hash are
Pure Swift. On ARM64 targets whose platform contract guarantees CRC32,
`VectorKernelsNative` contributes only the two-instruction cache-hash primitive.
On macOS, release codegen validation requires those intrinsics to inline into
the Swift hot loop. Other ARM64 targets use the same two-instruction kernel
behind one C ABI call. Targets without CRC32 use the Pure Swift pair hash.

## Low-level data path

The performance API borrows the input storage and writes directly into a
move-only, caller-owned token allocation:

```swift
import GigaTokenCore

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
