# zflate

A zlib-compatible deflate/inflate compression library and `gzip`-like CLI tool, written in Zig.

## What is it?

**zflate** is a from-scratch implementation of the DEFLATE algorithm (the same compression used by zlib, gzip, and PNG). It includes:

- A Zig library with deflate/inflate, raw deflate, and gzip format support
- A streaming compressor/decompressor API
- A command-line tool that works like `gzip`/`gunzip`

It was built as a learning project and benchmarked against the system's C zlib.

## Features

- **zlib format** — compatible with `zlib.compress` / `zlib.uncompress`
- **gzip format** — compatible with `gzip` / `gunzip`
- **Raw deflate** — for custom protocols
- **Streaming API** — `Compressor` and `Decompressor` structs for incremental I/O
- **Compression levels** — `.store`, `.fast`, `.default`, `.best`
- **Recursive mode** — `zflate -r dir/` compresses all files under a directory
- **Cross-tested** — roundtrip and cross-compatibility tests against system zlib

## Quick Start

### Build from source

```bash
git clone <repo>
cd zflate
zig build -Doptimize=ReleaseFast
```

### Install system-wide

```bash
sudo cp zig-out/bin/zflate /usr/local/bin/zflate
zflate --version   # zflate 1.0.0
```

### CLI usage

```bash
# Compress a file
zflate file.txt              # creates file.txt.gz, removes original

# Decompress
zflate -d file.txt.gz        # restores file.txt

# Keep the original
zflate -k file.txt

# Pipe through stdin/stdout
cat file.txt | zflate -c > file.txt.gz
zflate -dc < file.txt.gz

# Recursive
zflate -r my-folder/
zflate -dr my-folder/

# Fast or best compression
zflate -1 file.txt
zflate -9 file.txt
```

### Library usage

```zig
const zflate = @import("zflate");

// Compress
const compressed = try zflate.deflate(allocator, data);
defer allocator.free(compressed);

// Decompress
const decompressed = try zflate.inflate(allocator, compressed);
defer allocator.free(decompressed);

// Gzip
const gz = try zflate.gzipCompress(allocator, data, "file.txt", .default);
const result = try zflate.gzipDecompress(allocator, gz);
// result.data, result.filename
```

## Performance

Compared to system zlib on an ARM machine (ReleaseFast, 100 iterations averaged):

| File | zlib size | zflate size | zlib time | zflate time |
|------|-----------|-------------|-----------|-------------|
| alice29.txt | 54 KB | 56 KB | 1.8 ms | 4.5 ms |
| kennedy.xls | 210 KB | 225 KB | 6.2 ms | 11.5 ms |
| ptt5 | 55 KB | 59 KB | 1.9 ms | 5.8 ms |

zflate achieves ~3–7% worse compression ratios and is ~2× slower at compression than highly optimized C zlib. Decompression is ~5–10× slower. These gaps are expected for a straightforward implementation without SIMD, lazy evaluation, or optimal parsing.

## Running tests

```bash
zig test src/zflate.zig -lz -lc
```

All 15 tests pass, covering roundtrip, cross-compatibility with zlib, streaming, all compression levels, multi-block data, and gzip format.

## Why Zig?

Zig's comptime, explicit memory management, and C interop make it a great fit for systems code like compression. The goal was to see how close a clean Zig implementation could get to zlib in both compatibility and speed.

## License

MIT
