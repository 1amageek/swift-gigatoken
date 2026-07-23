# Rust comparison benchmark

Measured on 2026-07-23 using the same rank file, input bytes, and single-threaded
tokenizer path. Output equality is checked by token count and a byte-order-stable
FNV-1a checksum over every token ID. The table records the last accepted low-load
run; the reproduction script uses seven interleaved process pairs and reports
the median so host drift affects both implementations symmetrically.

```text
enwik8 16 MiB -> Swift encode -> 4,929,342 IDs -> 9bb0d84c9a7a327d
               Rust encode  -> 4,929,342 IDs -> 9bb0d84c9a7a327d
```

## Environment

| Item | Value |
|---|---|
| Machine | MacBook Pro, Apple M4 Max, 14 cores, 36 GB |
| OS | macOS 27.0 (26A5378n) |
| Swift | 6.3.1 RELEASE |
| Rust | nightly 1.99.0 (2026-07-21) |
| Rust reference | gigatoken 0.9.0, commit `542367a3efed134883fb4f1140b49c04e6fad3a3` |
| Model | `r50k_base.tiktoken`, SHA-256 `306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930` |
| Input | first 16 MiB of `enwik8`, SHA-256 `e6d287b341ea0dc183fb334ae05e558df4540752bf2be88da9570338fa711585` |

## Results

| Metric | Swift | Rust | Relative result |
|---|---:|---:|---:|
| Warm encode median | 670.50 MB/s | 652.36 MB/s | Swift 1.028x faster |
| Token IDs | 4,929,342 | 4,929,342 | exact |
| Token checksum | `9bb0d84c9a7a327d` | `9bb0d84c9a7a327d` | exact |

The current Swift implementation uses a NEON 64-byte classifier and, on the
benchmarked macOS ARM64 path, an inlined two-instruction ARM CRC32 cache hash.
Wasm/Embedded and other architectures use SWAR plus a Pure Swift hash. The hot
path also uses explicit L2/L1 prefetch, a raw aligned two-slot cache, branchless
home-pair probes, reusable merge scratch, persistent output cursors, and
four-entry fast-path unrolling. Both harnesses reuse their output buffers.
Native ARM64 uses a 25% maximum short-cache load to keep the common lookup in its
prefetched home pair; portable targets use 75% to bound memory use.

These are single-host observations rather than a portable throughput promise.
The reported gate passed four times consecutively with Swift/Rust ratios of
1.0128x, 1.0177x, 1.1259x, and 1.0278x while preserving the full token identity.
Absolute throughput still depends on processor, toolchain, and host load, so
release validation must rerun the interleaved gate rather than relying on this
recorded result.

## Reproduction

```bash
Benchmarks/run-comparison.sh /path/to/r50k_base.tiktoken /path/to/input
```

The script pins the Rust git revision through `Cargo.lock`, builds both release
binaries with native CPU optimization, alternates seven process pairs, writes
JSON results under the ignored `benchmark-results` directory, and exits with
failure when either token count or token checksum differs.
