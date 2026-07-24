# swift-gigatoken

Byte-level BPE tokenization with a Pure Swift portable data path for Native,
WebAssembly, and Embedded Swift, plus compile-time-gated native kernels where
the target contract guarantees the required instructions.

On an Apple M4 Max, the single-threaded warm `r50k_base` path reaches
**670.50 MB/s** while producing exactly the same token IDs as the reference
implementation.

## Acknowledgements

This project is an independent Swift implementation inspired by
[`gigatoken`](https://github.com/marcelroed/gigatoken), created by
[Marcel Roed](https://github.com/marcelroed). The original project established
the `gigatoken` name and demonstrated high-throughput language-model
tokenization. `swift-gigatoken` exists because of that work, and references to
this implementation's lineage should credit the original project and author.

## Performance

`swift-gigatoken` is designed for tokenizer hot paths where copying, allocation,
branching, and cache misses are measurable costs.

| 16 MiB `enwik8`, warm median | Throughput | Token IDs | Checksum |
|---|---:|---:|---:|
| `swift-gigatoken` | **670.50 MB/s** | 4,929,342 | `9bb0d84c9a7a327d` |
| Original Rust [`gigatoken`](https://github.com/marcelroed/gigatoken) 0.9.0 by Marcel Roed | 652.36 MB/s | 4,929,342 | `9bb0d84c9a7a327d` |

That result is **1.028x the throughput of the original Rust implementation**
on the same Apple M4 Max, model, input bytes, and single-threaded benchmark
path. The strict interleaved gate passed four consecutive times at 1.0128x,
1.0177x, 1.1259x, and 1.0278x, with full token identity on every run.

These are measured results on one machine rather than a universal throughput
guarantee. See [the complete benchmark methodology](Documentation/Benchmark.md)
for toolchain versions, pinned revisions, input hashes, and reproduction steps.

## Why it is fast

| Hot-path feature | Implementation |
|---|---|
| Zero-copy input and output | Borrows caller-owned UTF-8 bytes and writes directly into a reusable, move-only `TokenBuffer`. |
| 64-byte classification | Uses NEON on Apple ARM64 and SWAR on portable targets. |
| Two-instruction cache hashing | Emits two ARM `crc32x` instructions on supported ARM64 targets. |
| Cache-aware lookup | Uses aligned two-slot buckets, low native load factor, branchless home-pair probes, and explicit L2/L1 prefetch. |
| Reused working storage | Reuses token arenas, merge scratch, pretoken batches, caches, and output capacity across calls. |
| Batched output | Keeps a persistent output cursor and unrolls the common four-entry fast path. |
| Verified machine code | Release checks reject missing NEON, CRC32, or prefetch instructions and unexpected hot-loop calls. |

## Features

- Foundation-free `GigaTokenCore` with typed failures and no silent fallback.
- Native Apple ARM64 acceleration with a Pure Swift portable implementation.
- WebAssembly and Embedded Swift build and smoke-test coverage.
- Caller-owned, reusable storage for allocation-sensitive applications.
- Contiguous `UInt32` token access for MLX Swift, Core AI, and other runtimes.
- Exact `r50k_base` parity against pinned reference fixtures.

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
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm GigaTokenSmoke
swiftly run swift +6.3.1 ++ run --swift-sdk swift-6.3.1-RELEASE_wasm-embedded GigaTokenSmoke
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
