# Tokenizer comparison benchmarks

Measured on 2026-07-31 using the same rank file, input bytes, and single-threaded
ordinary-token path. Neither harness scans for special or added tokens. Output
equality is checked by token count and a byte-order-stable FNV-1a checksum over
every token ID. The table records the last accepted low-load run; the reproduction
script uses seven interleaved process pairs and reports the median so host drift
affects both implementations symmetrically.

```text
enwik8 16 MiB -> Swift encode -> 4,929,342 IDs -> 9bb0d84c9a7a327d
               Rust encode  -> 4,929,342 IDs -> 9bb0d84c9a7a327d
```

## Environment

| Item | Value |
|---|---|
| Machine | MacBook Pro, Apple M4 Max, 14 cores, 36 GB |
| OS | macOS 27.0 (26A5378n) |
| Swift used for the recorded result | `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a`, compiler `ef761e567dc94ee` |
| Rust | nightly 1.99.0 (2026-07-21) |
| Rust reference | [gigatoken](https://github.com/marcelroed/gigatoken) 0.9.0 by [Marcel Roed](https://github.com/marcelroed), commit `542367a3efed134883fb4f1140b49c04e6fad3a3` |
| Model | `r50k_base.tiktoken`, SHA-256 `306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930` |
| Input | first 16 MiB of `enwik8`, SHA-256 `e6d287b341ea0dc183fb334ae05e558df4540752bf2be88da9570338fa711585` |

## Results

| Metric | Swift | Rust | Relative result |
|---|---:|---:|---:|
| Warm encode median | 988.76 MB/s | 975.45 MB/s | Swift 1.014x faster |
| Token IDs | 4,929,342 | 4,929,342 | exact |
| Token checksum | `9bb0d84c9a7a327d` | `9bb0d84c9a7a327d` | exact |

The current Swift implementation uses a NEON 64-byte classifier and, on the
benchmarked macOS ARM64 path, an inlined two-instruction ARM CRC32 cache hash.
Wasm/Embedded and other architectures use SWAR plus a Pure Swift hash. The hot
path also uses explicit L2/L1 prefetch, a raw aligned two-slot cache, branchless
home-pair probes, reusable merge scratch, one segment-wide closure-scoped
`MutableSpan` output cursor, and a bounds-proven four-entry store. Both
harnesses reuse their output buffers.
Native ARM64 uses a 25% maximum short-cache load to keep the common lookup in its
prefetched home pair; portable targets use 75% to bound memory use.

This comparison measures compatibility and performance against the original
project. It does not imply authorship of, affiliation with, or endorsement by
the original author.

These are single-host observations rather than a portable throughput promise.
The accepted strengthened gate measured a 1.0136x Swift/Rust ratio and 4.32%
paired common-mode drift while preserving full token identity in every process.
Absolute throughput still depends on processor, toolchain, and host load. The
script therefore rejects concurrent compiler/build activity and paired
common-mode drift above 5% as an invalid environment rather than reporting a
performance pass or failure.

The package's recorded result and current build baseline are both
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a` at compiler commit
`ef761e567dc94ee`; the reproduction scripts use that pinned toolchain.

## Reproduction

```bash
Benchmarks/run-comparison.sh /path/to/r50k_base.tiktoken /path/to/input
```

The script pins the Rust git revision through `Cargo.lock`, builds both release
binaries with native CPU optimization, waits for five build-free host
observations, and alternates seven process pairs. A timestamped directory under
ignored `benchmark-results` retains every process JSON, the raw sample table,
power source, and binary/model/input hashes. Concurrent build activity or more
than 5% paired common-mode drift exits with environment status 75; token
identity mismatch or Swift/Rust throughput below 1.0 fails the gate.

## General-purpose tokenizer APIs

A separate run recorded on 2026-07-31 compares the public encode APIs of
`swift-gigatoken`, the original Rust `gigatoken`, OpenAI `tiktoken`, and
Hugging Face `tokenizers`. This answers the application-level question of how
quickly each package turns the same input into an owned sequence of token IDs.

```text
                     same 16 MiB UTF-8 input
                                |
       +------------------------+-------------------------+
       |                        |                         |
  Swift/Rust bytes       tiktoken Python text    Hugging Face Python text
       |                        |                         |
       +------------------------+-------------------------+
                                |
           4,929,342 IDs / 9bb0d84c9a7a327d
```

### Additional environment

| Item | Value |
|---|---|
| Python | CPython 3.12.8 |
| OpenAI tokenizer | `tiktoken` 0.12.0, `r50k_base` |
| Hugging Face tokenizer | `tokenizers` 0.22.1, `openai-community/gpt2` revision `607a30d783dfa663caf39e06633721c8d4cfcd7e` |
| Parallelism | One caller thread; `RAYON_NUM_THREADS=1`; `TOKENIZERS_PARALLELISM=false` |
| Iterations | One cold encode followed by seven warm encodes; warm median reported |

### Results

| Public encode API | Warm median | Relative to Swift | Output verification |
|---|---:|---:|---:|
| `swift-gigatoken` | **667.27 MB/s** | 1.00x | baseline |
| Original Rust `gigatoken` 0.9.0 | 603.56 MB/s | Swift 1.11x | count + checksum match |
| OpenAI `tiktoken` 0.12.0 | 9.29 MB/s | Swift **71.82x** | count + checksum match |
| Hugging Face `tokenizers` 0.22.1 | 1.30 MB/s | Swift **514.88x** | count + checksum match |

This is an end-to-end public-API comparison, not an isolated comparison of
native tokenizer kernels. The timed region includes the encode call and its
required output token-list materialization. Input file I/O, UTF-8 decoding for
the Python APIs, model loading, garbage collection, and checksum calculation
are outside that region. Garbage collection runs before each Python iteration
so the preceding multi-million-element output list is not retained during the
next measurement.

All four results are rejected unless their token count and full FNV-1a token
checksum equal the Swift result. The Python dependency versions and the
Hugging Face model revision are pinned. The model is stored in the standard
Hugging Face cache rather than inside this repository.

### Reproduction

```bash
Benchmarks/run-general-comparison.sh /path/to/r50k_base.tiktoken /path/to/input
```

The script creates a Python virtual environment under `.build`, installs the
pinned packages, builds the two native release binaries with native CPU
optimization, runs every implementation, verifies full-output identity, and
writes JSON results under `benchmark-results/general`. Throughput uses decimal
megabytes per second (`input byte count / elapsed seconds / 1,000,000`).
