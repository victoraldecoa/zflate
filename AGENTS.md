 # zflate

A zlib-compatible deflate/inflate compression library written in Zig, with a `gzip`-like CLI tool.

## Build & Test

- **Zig version:** `0.17.0-dev.644+3de725074` at `/home/vagrant/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/aarch64-linux-0.17.0-dev.644+3de725074/zig`
- **Build binary:** `zig build -Doptimize=ReleaseFast`
- **Run tests:** `zig test src/zflate.zig -lz -lc`
- **Run benchmark:** `zig build run -Doptimize=ReleaseFast`
- **Install system-wide:** `sudo cp zig-out/bin/zflate /usr/local/bin/zflate`

The project links C zlib (`-lz -lc`) via `extern "c"` for benchmark comparison and cross-compatibility tests.

## Project Structure

| File | Purpose |
|------|---------|
| `src/zflate.zig` | Library: deflate/inflate, gzip compress/decompress, streaming API |
| `src/main.zig` | CLI tool (`zflate`) — gzip-compatible command-line interface |
| `build.zig` | Zig build script |
| `build.zig.zon` | Package manifest |

Test data (Canterbury Corpus) lives in the project root but is **not committed** (see `.gitignore`).

## Public API

```zig
// zlib-format deflate/inflate
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
pub const Decompressor = struct { decompress, decompressRaw };
```

## CLI Usage (`zflate`)

Installed to `/usr/local/bin/zflate`. Behaves like `gzip`:

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
```

## Coding Conventions

- **Keep it simple.** The codebase prioritizes correctness and readability over micro-optimizations.
- **Minimal changes.** When fixing bugs or adding features, make the smallest change that achieves the goal.
- **Follow existing style.** Match the surrounding code's formatting and naming.
- **Test everything.** All changes must pass the existing 15 tests. Add new tests for new features.
- **No git mutations** (commit/push/rebase/etc.) unless explicitly asked.

## Important Implementation Details

- **Block size:** Inputs ≤ 128KB use a single block; larger inputs use 128KB blocks with a persistent `Matcher` for cross-block back-references.
- **Matcher state:** The LZ77 hash-chain matcher persists across block boundaries. Match lengths are capped at block boundaries to prevent output duplication.
- **Extra bits:** Huffman codes are MSB-first (reversed via `reverseBits`), but extra bits are plain LSB-first integers. Do NOT reverse extra bits.
- **Huffman table size:** `HUFFMAN_TABLE_SIZE = 1 << 15 = 32768`.
- **Gzip trailer:** CRC32 and ISIZE are little-endian. The trailer is read from `input.len - 8`.

## Performance (ReleaseFast)

| File | zlib size | zflate size | zlib compress | zflate compress |
|------|-----------|-------------|---------------|-----------------|
| alice29.txt | 54,108 | 56,104 | 1.82 ms | 4.47 ms |
| kennedy.xls | 210,198 | 224,961 | 6.16 ms | 11.48 ms |
| ptt5 | 55,311 | 58,782 | 1.90 ms | 5.81 ms |

zflate is ~0.3–0.5× zlib compress speed and ~0.1× decompress speed. The gap is expected for a straightforward implementation without SIMD, lazy evaluation, or optimal parsing.

## Tests

Run all tests with:
```bash
zig test src/zflate.zig -lz -lc
```

Tests cover: roundtrip (empty/small/large), zlib cross-compatibility (both directions), streaming compressor, all compression levels, multi-block large data, and gzip roundtrip.
