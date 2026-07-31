# swift-gigatoken architecture

`swift-gigatoken` is an independent Swift implementation inspired by
Marcel Roed's original [`gigatoken`](https://github.com/marcelroed/gigatoken)
project. It implements its own public API, ownership model, pretokenization, and
BPE algorithm in Swift. A minimal optional C intrinsic boundary emits
architecture-specific instructions. The original Rust implementation is used
only as an external correctness and benchmark reference.

```text
mapped .tiktoken bytes (host only)
        │ direct line parse + Base64 decode
        ▼
packed token bytes + UInt32 offsets ──→ BPEModel
                                         │ immutable pair-rank table
borrowed input bytes ─────────────────────┤
                                         ▼
                              R50K scan → pair hash → short-key cache → BPE
                                             │
                                             ├─ Pure Swift portable hash
                                             └─ ARM CRC32 native hash
                                         │
                                         ▼
                              caller-owned TokenBuffer
```

## Target boundaries

- `GigaTokenCore` contains the source-of-truth algorithm and depends on
  `VectorKernels` plus its capability-gated `VectorKernelsNative` instruction
  target.
- `GigaToken` owns host conveniences such as Foundation file loading and `.tiktoken` Base64 parsing.
- `GigaTokenBenchmark` measures model construction, cold encoding, and warm encoding independently.

## Storage and ownership contract

| Boundary | Ownership | Copy behavior |
|---|---|---|
| `.tiktoken` file input | `Data` owned by host loader, mapped when the platform permits | parsed through a borrowed byte view |
| Base64 token payload | final packed model storage | decoded directly; no per-token `Data` or `[UInt8]` |
| `BPEModel` token data | one `[UInt8]` plus `[UInt32]` offsets | slices are ranges, not nested arrays |
| encode input | caller-owned borrowed buffer | no input copy on buffer overloads |
| encode output | move-only `TokenBuffer` | direct write through a closure-scoped, `~Escapable` `MutableSpan` cursor; reusable allocation |
| short pretoken cache | encoder-owned raw allocation | 32-byte entries, 64-byte pair buckets, 2 MiB native alignment for large tables; native ARM64 grows at 25% load for home-pair speed, portable targets at 75% for memory discipline |
| long pretoken cache | encoder-owned byte/token arenas plus ranges | copies a key once on a cold ownership boundary; warm lookup borrows the input and reuses stored ranges |
| convenience `String` / array APIs | returned owned value | materializes at the explicit API boundary |

The cache, token arena, merge scratch, and output allocation are reused after
warm-up. Tests assert stable capacities and the required cache alignment across
repeated identical encodes. That is a storage-reuse guarantee; it is not
presented as a whole-process proof that the Swift runtime performs zero
allocations.

`TokenBuffer` is the exactly-once owner of its initialized `UInt32` allocation.
Its inline four-lane store uses three initialized guard lanes beyond the logical
append budget; only the logical token count is committed. `ShortPretokenCache`
similarly owns and binds its bucket allocation once. Cache probe and prefetch
pointers are consumed within one method call, so neither output nor cache
pointers can survive a grow operation.

## Concurrency and synchronization contract

`BPEModel` is immutable and `Sendable`, so callers may share one model across
tasks, threads, and supported Embedded execution contexts. `BPEEncoder` and
`GigaTokenizer` are move-only mutable values. Each instance exclusively owns
its short cache, long cache, token arena, merge workspace, and pretoken scratch
allocation. Their mutating API makes concurrent access to one instance invalid
rather than silently serializing the tokenizer hot path.

```text
                         shared immutable BPEModel
                           /        |        \
                          /         |         \
                 encoder A    encoder B    encoder C
                 owned state  owned state  owned state
```

No current production path has shared mutable state, so adding a mutex would
protect no valid sharing boundary and would add lock traffic to every encode.
If a future API introduces shared mutable memory, Native, Wasm, and Embedded
targets must use the same `Synchronization.Mutex<State>` exclusion contract.
Target differences belong in the linked platform implementation, not in an
`hasFeature(Embedded)` synchronization bypass. ISR and DMA callbacks must hand
work to task/thread context through target-appropriate atomics, a bounded
queue, or an interrupt-safe critical section before tokenizer state is used.

## Correctness contract

- Merge priority is the mergeable-rank token ID, matching tiktoken-style vocabularies.
- Pretokenization implements the GPT-2/r50k expression.
- Unsupported or malformed input fails with `TokenizerError`; the implementation does not silently substitute a different tokenizer behavior.
- Performance changes must preserve the reference parity corpus, typed-failure tests, and full-input token checksum before becoming the default.

The Unicode property table is generated from pinned `regex` Unicode data by
`Scripts/generate-unicode-class-table.py`. The reference token IDs in
`r50k_parity.json` and the 110,126-byte `r50k_long_parity.json` are regenerated
or verified through pinned Python
`tiktoken` by `Scripts/generate-r50k-parity.py`. Their dependencies are fixed
in `Scripts/requirements-generation.txt`; generated artifacts are never
silently accepted when a check differs.

## Portability contract

The fixed baseline is Swift
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a` at compiler commit
`ef761e567dc94ee`, with the matching standard and Embedded Wasm SDKs.
Validation logs the exact toolchain, compiler commit, SDK identifiers, and
`wasm32-unknown-wasip1` target triple before compiling.

The portable path does not use Foundation, filesystem APIs, OS threads, memory
mapping, or foreign-language algorithms. Host model parsing remains outside the
core. Wasm and Embedded Swift callers can provide packed token storage and
offsets directly to `BPEModel`, allowing model data to be embedded without
runtime JSON or Base64 parsing. Platform-specific alignment is disabled on
wasm32 while the same tokenizer semantics and typed failures remain active.

The native module is an instruction-emission shim, not a second tokenizer
implementation. A static-inline C intrinsic emits cache prefetch hints without
using Swift-to-LLVM symbol coupling. On ARM64 it also uses the SDK target's
CRC32 capability constant; on Wasm and Embedded-Wasm the multiplicative hash is
selected while prefetch remains a semantic hint. The hash affects only cache
placement, so token IDs and errors remain backend-independent. Standard and
Embedded Wasm smoke executables run eight task-group encoders over one shared
immutable model and require every result to match.

## ML runtime interoperability contract

MLX Swift, Core AI, and other tensor runtimes are adapter consumers rather than
dependencies of this package. The core keeps that boundary stable through
standard-library types:

```text
runtime-owned UTF-8 bytes
        │ scoped UnsafeBufferPointer<UInt8>
        ▼
TokenEncoding ──→ caller-owned TokenBuffer
                         │
                         ├─ scoped UnsafeBufferPointer<TokenID>
                         └─ scoped UnsafeBufferPointer<UInt32>
                                  via withUnsafeRawTokenIDs
```

- `TokenEncoding` includes the borrowed-input and `TokenBuffer` output methods;
  adapters can depend on the protocol without importing the host loader.
- Appending encode and decode operations are transactional. A typed failure
  leaves the caller-owned output at its original count and contents.
- `TokenID` is frozen over `UInt32`, and `TokenBuffer.withUnsafeRawTokenIDs`
  exposes its contiguous storage for the duration of a closure without copying.
- `TokenByteDecoding` exposes borrowed token-byte views and reusable decoded
  byte output.
- The buffer pointers are scoped borrows. Adapters must finish runtime tensor
  construction inside the closure or arrange their own explicit ownership
  transfer; a pointer must not escape its closure.
- Borrow callbacks may throw; callback failures propagate through the scoped
  view instead of requiring a temporary `Result` allocation.
- Runtime-specific tensor ownership, device transfer, and integer conversion
  remain adapter responsibilities. No adapter is included in this package.
