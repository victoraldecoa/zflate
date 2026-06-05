# zflate

A zlib-compatible deflate/inflate compression library written in Zig, accompanied by a `gzip`-like CLI tool named `zflate`.

## Technology Stack

- **Language:** Zig (target version `0.17.0-dev.644+3de725074`)
- **Build System:** Native Zig build (`build.zig` / `build.zig.zon`)
- **External Dependency:** C zlib (`libz`) is linked (`-lz -lc`) via `extern "c"` for cross-compatibility verification in tests.
- **Platform:** Developed and tested on Linux aarch64. The CLI produces ELF64 executables.

## Project Structure

| Path | Purpose |
|------|---------|
| `build.zig` | Zig build script — defines the `zflate` module, CLI executable, test step, and run step. |
| `build.zig.zon` | Package manifest. Name: `.zflate`, version `0.0.0`, minimum Zig version `0.17.0-dev.644+3de725074`. |
| `src/zflate.zig` | **Core library** (~1700 lines). Contains deflate, inflate, gzip, raw deflate/inflate, streaming API, Huffman/LZ77 internals, and all tests. |
| `src/main.zig` | **CLI entry point** (`zflate` binary). Parses arguments and dispatches to `src/zflate.zig`. |
| `src/root.zig` | Minimal re-export module for package consumers (re-exports `deflate`, `inflate`, `deflateRaw`, `inflateRaw`). |

Temporary debug artifacts (`debug*.zig`, `debug_zlib*`, `bench_opt`) and Canterbury Corpus benchmark files (e.g., `alice29.txt`, `kennedy.xls`) exist in the project root but are **not committed** (see `.gitignore`).

## Build & Test Commands

Use the Zig binary at:
```
/home/vagrant/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/aarch64-linux-0.17.0-dev.644+3de725074/zig
```

**Build the CLI (ReleaseFast):**
```bash
zig build -Doptimize=ReleaseFast
```
Produces `zig-out/bin/zflate`.

**Run tests:**
```bash
zig test src/zflate.zig -lz -lc
```
There are **15 tests** embedded in `src/zflate.zig`. All must pass.

**Run via build system:**
```bash
zig build test      # Runs the module tests
zig build run       # Builds and runs the CLI; pass extra args after --
```

**Install system-wide:**
```bash
sudo cp zig-out/bin/zflate /usr/local/bin/zflate
```

## Public API

```zig
// Zlib-format deflate/inflate
pub fn deflate(allocator, input) Error![]u8;
pub fn deflateWithLevel(allocator, input, level) Error![]u8;
pub fn inflate(allocator, input) Error![]u8;

// Raw deflate (no zlib wrapper)
pub fn deflateRaw(allocator, input) Error![]u8;
pub fn deflateRawWithLevel(allocator, input, level) Error![]u8;
pub fn inflateRaw(allocator, input) Error![]u8;

// Gzip format
pub fn gzipCompress(allocator, input, filename, level) Error![]u8;
pub fn gzipDecompress(allocator, input) Error!struct { data: []u8, filename: ?[]const u8 };

// Compression levels
pub const CompressionLevel = enum { store, fast, default, best };

// Streaming API
pub const Compressor = struct { init, write, finish, deinit };
pub const Decompressor = struct { init, decompress, decompressRaw };
```

**Error set (`Error`):** `InvalidData`, `InvalidHuffmanCode`, `InvalidBlockType`, `InvalidDistance`, `InvalidLength`, `CorruptInput`, `EndOfStream`, `AdlerMismatch`, `OutOfMemory`.

## CLI Usage (`zflate`)

The installed binary behaves like `gzip`:

```bash
zflate file.txt              # → file.txt.gz, removes original
zflate -d file.txt.gz        # → file.txt, removes .gz
zflate -k file.txt           # keep original
zflate -c < file.txt         # compress to stdout
zflate -dc < file.txt.gz     # decompress to stdout
zflate -r dir/               # recursive compress
zflate -dr dir/              # recursive decompress
zflate -1 .. -9              # compression level
zflate -0                    # store (no compression)
zflate -t file.txt.gz        # test integrity
zflate -l file.txt.gz        # list compression info
zflate -S .zz file.txt       # custom suffix
```

Supported flags include `-d`, `-c`, `-k`, `-f`, `-v`, `-t`, `-l`, `-n`, `-N`, `-q`, `-r`, `-s`, `-T`, `-h`, `-V`, `-L`, `-S`, and numeric levels `-0` through `-9`.

## Code Organization

`src/zflate.zig` is a monolithic library file divided into these logical sections:

1. **Checksums** — `adler32`, `adler32Update`, `crc32` (CRC-32 table is comptime-generated).
2. **Bit I/O** — `BitReader` (MSB-first buffered bit consumption) and `BitWriter` (LSB-first buffered bit emission). `BitWriter` is public.
3. **Huffman** — `HuffmanTable` (lookup-table decoder), `buildHuffmanLengths` (package-merge-like length-limited construction using a heap + tree depth adjustment), `computeCodes`, and comptime precomputed fixed Huffman tables/codes.
4. **Length/Distance tables** — Standard deflate base and extra-bits tables.
5. **Inflate** — `inflateStored`, `inflateFixed`, `inflateDynamic`, `copyFromOutput`, and the top-level `inflate` / `inflateRaw` functions.
6. **Deflate / LZ77** — `Matcher` (hash-chain LZ77 matcher with a 32KB window, 15-bit hash, adaptive chain limits), `encodeLength`, `encodeDistance`, `deflateDynamicBlock`, `deflateFixedBlock`, `deflateStoredBlock`, `deflateBlock`, `deflateBlocks`, and top-level `deflate` / `deflateWithLevel` / `deflateRaw` / `deflateRawWithLevel`.
7. **Gzip** — `gzipCompress` and `gzipDecompress` (header parsing, FEXTRA/FNAME/FCOMMENT/FHCRC skipping, little-endian CRC32+ISIZE trailer validation).
8. **Streaming API** — `Compressor` (buffers input, updates Adler-32 incrementally, emits zlib wrapper) and `Decompressor` (thin wrapper around `inflate` / `inflateRaw`).
9. **Tests** — 15 tests covering roundtrip, zlib cross-compatibility, raw deflate, streaming, all compression levels, multi-block large data, and gzip roundtrip.

`src/main.zig` is strictly the CLI layer: argument parsing, file/stdin I/O using `std.Io`, directory walking, and dispatch to the library.

## Testing Strategy

- All tests live in `src/zflate.zig` and use `std.testing.allocator`.
- **15 tests** (verified passing):
  1. `roundtrip empty`
  2. `roundtrip hello`
  3. `roundtrip alice29 first 1KB`
  4. `zflate deflate -> zlib inflate`
  5. `zlib deflate -> zflate inflate`
  6. `zflate deflate -> zlib inflate empty`
  7. `zflate deflate -> zlib inflate single byte`
  8. `raw deflate roundtrip`
  9. `streaming compressor roundtrip`
  10. `compression level store`
  11. `compression level fast`
  12. `compression level best`
  13. `multi-block roundtrip large data`
  14. `gzip roundtrip`
  15. `gzip roundtrip empty`
- Cross-compatibility tests call C `compress` / `uncompress` from `libz` to verify bitstream interoperability.
- When adding new features or fixing bugs, add a targeted test and ensure all 15 existing tests still pass.

## Important Implementation Details

- **Block sizing:** Inputs ≤ 128KB use a single deflate block. Larger inputs are split into 128KB blocks. The `Matcher` state persists across block boundaries so back-references can cross block boundaries, but match lengths are capped at block ends to prevent output duplication.
- **Huffman codes:** Codes are MSB-first; the encoder uses `reverseBits` to map canonical codes into LSB-first lookup keys. **Extra bits** (length/distance offsets) are plain LSB-first integers and must **not** be reversed.
- **Huffman table size:** `HUFFMAN_TABLE_SIZE = 1 << 15 = 32768`. Decoding peeks 15 bits from the bit buffer.
- **Compression heuristic:**
  - `store` level or blocks < 32 bytes → stored (uncompressed) block.
  - Blocks < 256 bytes → fixed Huffman block.
  - Otherwise → dynamic Huffman block.
- **Gzip trailer:** CRC32 and ISIZE are little-endian. The trailer is read from `input.len - 8`.
- **Zlib header:** `deflate` emits the standard `0x78 0x9C` header followed by raw deflate blocks and a big-endian Adler-32 checksum.

## Performance (ReleaseFast)

Benchmarked against C zlib on Canterbury Corpus files:

| File | zlib size | zflate size | zlib compress | zflate compress |
|------|-----------|-------------|---------------|-----------------|
| alice29.txt | 54,108 | 56,104 | ~1.82 ms | ~4.47 ms |
| kennedy.xls | 210,198 | 224,961 | ~6.16 ms | ~11.48 ms |
| ptt5 | 55,311 | 58,782 | ~1.90 ms | ~5.81 ms |

zflate is roughly **0.3–0.5× zlib compress speed** and **~0.1× decompress speed**. This is expected for a straightforward implementation without SIMD, lazy evaluation, or optimal parsing.

## Coding Conventions

- **Keep it simple.** Prioritize correctness and readability over micro-optimizations.
- **Make minimal changes.** When fixing bugs or adding features, change the smallest amount of code that achieves the goal.
- **Follow existing style.** Match surrounding formatting, naming, and comment patterns.
- **Test everything.** All changes must pass the existing 15 tests.
- **No git mutations** (commit, push, rebase, etc.) unless explicitly requested.

## Security Considerations

- The inflate path validates Adler-32 (zlib) and CRC32 + ISIZE (gzip). Invalid checksums return `error.AdlerMismatch` or `error.InvalidData`.
- `BitReader` has two modes: `ensureBits` (strict, returns `EndOfStream`) and `ensureBitsPad` (permissive, used only during Huffman decoding where over-read is harmless). Inflate uses the strict mode for structural reads.
- Distance bounds are checked against the output buffer length; out-of-range distances return `error.InvalidDistance`.
- Stored blocks validate `len == ~nlen` to detect corruption early.
- The library allocates output buffers via the caller-provided allocator; there are no fixed internal size limits beyond standard deflate constraints (max match length 258, window 32KB).
