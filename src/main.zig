const std = @import("std");
const Io = std.Io;
const zflate = @import("zflate");

const usage =
    \\Usage: zflate [OPTIONS] [FILE...]
    \\Compress or decompress files in gzip format.
    \\   Options:
    \\  -d, --decompress  Decompress
    \\  -c, --stdout      Write to stdout, keep original files
    \\  -k, --keep        Keep input files
    \\  -1, --fast        Fastest compression
    \\  -9, --best        Best compression
    \\  -0, --store       No compression
    \\  -h, --help        Show this help
    \\  -V, --version     Show version
    \\  -t, --test        Test compressed file integrity
    \\  -v, --verbose     Verbose mode
    \\  -f, --force       Force overwrite
    \\  -l, --list        List compression info
    \\  -L, --license     Show license
    \\  -n, --no-name     Do not save or restore original file name
    \\  -N, --name        Save or restore original file name
    \\  -q, --quiet       Suppress warnings
    \\  -r, --recursive   Operate recursively on directories
    \\  -S, --suffix=SUF  Use suffix SUF instead of .gz
    \\  -s, --small       Use less memory
    \\  -V, --version     Show version
    \\  -1 .. -9          Compression level (default: 6)
    \\  --fast            Compress faster
    \\  --best            Compress better
;

const CliOptions = struct {
    decompress: bool = false,
    stdout: bool = false,
    keep: bool = false,
    force: bool = false,
    verbose: bool = false,
    test_integrity: bool = false,
    list: bool = false,
    no_name: bool = false,
    quiet: bool = false,
    recursive: bool = false,
    level: zflate.CompressionLevel = .default,
    suffix: []const u8 = ".gz",
};

fn parseArgsZ(args: []const [:0]const u8) !struct { opts: CliOptions, files: [][]const u8 } {
    var opts = CliOptions{};
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(std.heap.page_allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--decompress")) {
            opts.decompress = true;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            opts.stdout = true;
        } else if (std.mem.eql(u8, arg, "--keep")) {
            opts.keep = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--test")) {
            opts.test_integrity = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            opts.list = true;
        } else if (std.mem.eql(u8, arg, "--no-name")) {
            opts.no_name = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--best")) {
            opts.level = .best;
        } else if (std.mem.eql(u8, arg, "--store")) {
            opts.level = .store;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            opts.level = .fast;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zflate 1.0.0\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--license")) {
            std.debug.print("zflate is free software, released under the MIT license.\n", .{});
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-S")) {
            if (arg.len > 2) {
                opts.suffix = arg[2..];
            } else {
                i += 1;
                if (i >= args.len) return error.MissingSuffix;
                opts.suffix = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Handle combined short flags like -dc, -kf, etc.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'd' => opts.decompress = true,
                    'c' => opts.stdout = true,
                    'k' => opts.keep = true,
                    'f' => opts.force = true,
                    'v' => opts.verbose = true,
                    't' => opts.test_integrity = true,
                    'l' => opts.list = true,
                    'n' => opts.no_name = true,
                    'q' => opts.quiet = true,
                    'r' => opts.recursive = true,
                    'h' => {
                        std.debug.print("{s}\n", .{usage});
                        std.process.exit(0);
                    },
                    'V' => {
                        std.debug.print("zflate 1.0.0\n", .{});
                        std.process.exit(0);
                    },
                    'L' => {
                        std.debug.print("zflate is free software, released under the MIT license.\n", .{});
                        std.process.exit(0);
                    },
                    '0' => opts.level = .store,
                    '1' => opts.level = .fast,
                    '2'...'8' => opts.level = .default,
                    '9' => opts.level = .best,
                    else => {
                        std.debug.print("zflate: unrecognized option '-{c}'\nTry 'zflate --help' for more information.\n", .{arg[j]});
                        std.process.exit(1);
                    },
                }
            }
        } else {
            try files.append(std.heap.page_allocator, arg);
        }
    }

    return .{ .opts = opts, .files = try files.toOwnedSlice(std.heap.page_allocator) };
}

fn compressFile(allocator: std.mem.Allocator, io: Io, path: []const u8, opts: CliOptions) !void {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);

    const filename = if (opts.no_name) null else path;
    const compressed = try zflate.gzipCompress(allocator, data, filename, opts.level);
    defer allocator.free(compressed);

    if (opts.stdout) {
        try writeAllStdout(compressed);
    } else {
        const out_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, opts.suffix });
        defer allocator.free(out_path);

        if (!opts.force) {
            _ = Io.Dir.cwd().access(io, out_path, .{}) catch {
                // file doesn't exist, ok to proceed
                try writeFile(io, out_path, compressed);
                if (!opts.keep) {
                    try Io.Dir.cwd().deleteFile(io, path);
                }
                if (opts.verbose) {
                    std.debug.print("{s}: {d} bytes -> {d} bytes ({d:.1}%)\n", .{
                        path,
                        data.len,
                        compressed.len,
                        @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(data.len)) * 100.0,
                    });
                }
                return;
            };
            if (!opts.quiet) {
                std.debug.print("zflate: {s} already exists; not overwritten (use -f to force)\n", .{out_path});
            }
            std.process.exit(1);
        }

        try writeFile(io, out_path, compressed);
        if (!opts.keep) {
            try Io.Dir.cwd().deleteFile(io, path);
        }
        if (opts.verbose) {
            std.debug.print("{s}: {d} bytes -> {d} bytes ({d:.1}%)\n", .{
                path,
                data.len,
                compressed.len,
                @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(data.len)) * 100.0,
            });
        }
    }
}

fn decompressFile(allocator: std.mem.Allocator, io: Io, path: []const u8, opts: CliOptions) !void {
    const compressed = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(compressed);

    const result = try zflate.gzipDecompress(allocator, compressed);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);

    if (opts.stdout) {
        try writeAllStdout(result.data);
    } else {
        const out_path = blk: {
            if (result.filename) |name| {
                break :blk try allocator.dupe(u8, name);
            } else if (std.mem.endsWith(u8, path, opts.suffix)) {
                break :blk try allocator.dupe(u8, path[0 .. path.len - opts.suffix.len]);
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.out", .{path});
            }
        };
        defer allocator.free(out_path);

        if (!opts.force) {
            _ = Io.Dir.cwd().access(io, out_path, .{}) catch {
                try writeFile(io, out_path, result.data);
                if (!opts.keep) {
                    try Io.Dir.cwd().deleteFile(io, path);
                }
                if (opts.verbose) {
                    std.debug.print("{s}: {d} bytes -> {d} bytes\n", .{
                        path,
                        compressed.len,
                        result.data.len,
                    });
                }
                return;
            };
            if (!opts.quiet) {
                std.debug.print("zflate: {s} already exists; not overwritten (use -f to force)\n", .{out_path});
            }
            std.process.exit(1);
        }

        try writeFile(io, out_path, result.data);
        if (!opts.keep) {
            try Io.Dir.cwd().deleteFile(io, path);
        }
        if (opts.verbose) {
            std.debug.print("{s}: {d} bytes -> {d} bytes\n", .{
                path,
                compressed.len,
                result.data.len,
            });
        }
    }
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn readAllStdin(allocator: std.mem.Allocator) ![]u8 {
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n < 0) {
            std.debug.print("zflate: read error\n", .{});
            return error.ReadFailed;
        }
        if (n == 0) break;
        try data.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return data.toOwnedSlice(allocator);
}

fn writeAllStdout(data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(1, data[written..].ptr, data.len - written);
        if (n < 0) {
            std.debug.print("zflate: write error\n", .{});
            return error.WriteFailed;
        }
        written += @intCast(n);
    }
}

fn compressStdin(allocator: std.mem.Allocator, opts: CliOptions) !void {
    const data = try readAllStdin(allocator);
    defer allocator.free(data);
    const compressed = try zflate.gzipCompress(allocator, data, null, opts.level);
    defer allocator.free(compressed);
    try writeAllStdout(compressed);
}

fn decompressStdin(allocator: std.mem.Allocator) !void {
    const data = try readAllStdin(allocator);
    defer allocator.free(data);
    const result = try zflate.gzipDecompress(allocator, data);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);
    try writeAllStdout(result.data);
}

fn testFile(allocator: std.mem.Allocator, io: Io, path: []const u8, quiet: bool) !void {
    const compressed = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(compressed);

    const result = try zflate.gzipDecompress(allocator, compressed);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);

    if (!quiet) {
        std.debug.print("{s}: OK\n", .{path});
    }
}

fn listFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    const compressed = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(compressed);

    const result = try zflate.gzipDecompress(allocator, compressed);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);

    const ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(result.data.len)) * 100.0;
    std.debug.print("{s:>20} {s:>20} {d:>6.1}%\n", .{
        path,
        if (result.filename) |n| n else "",
        ratio,
    });
}

fn processDirectory(allocator: std.mem.Allocator, io: Io, base_path: []const u8, opts: CliOptions) !void {
    const dir = Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch |err| {
        std.debug.print("zflate: can't open directory '{s}': {s}\n", .{ base_path, @errorName(err) });
        std.process.exit(1);
    };

    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;

        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
        defer allocator.free(full_path);

        if (opts.decompress) {
            if (std.mem.endsWith(u8, full_path, opts.suffix)) {
                decompressFile(allocator, io, full_path, opts) catch |err| {
                    if (!opts.quiet) {
                        std.debug.print("zflate: {s}: {s}\n", .{ full_path, @errorName(err) });
                    }
                };
            }
        } else {
            compressFile(allocator, io, full_path, opts) catch |err| {
                if (!opts.quiet) {
                    std.debug.print("zflate: {s}: {s}\n", .{ full_path, @errorName(err) });
                }
            };
        }
    }
}

fn processFile(allocator: std.mem.Allocator, io: Io, path: []const u8, opts: CliOptions) !void {
    if (opts.test_integrity) {
        try testFile(allocator, io, path, opts.quiet);
    } else if (opts.list) {
        try listFile(allocator, io, path);
    } else if (opts.decompress) {
        try decompressFile(allocator, io, path, opts);
    } else {
        try compressFile(allocator, io, path, opts);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args_slice = try init.minimal.args.toSlice(allocator);

    const parsed = parseArgsZ(args_slice[1..]) catch |err| {
        switch (err) {
            error.MissingSuffix => {
                std.debug.print("zflate: option requires an argument -- 'S'\n", .{});
                std.process.exit(1);
            },
            else => {
                std.debug.print("zflate: error parsing arguments\n", .{});
                std.process.exit(1);
            },
        }
    };

    if (parsed.files.len == 0 and !parsed.opts.stdout) {
        if (parsed.opts.test_integrity or parsed.opts.list) {
            std.debug.print("zflate: no files specified\n", .{});
            std.process.exit(1);
        }
        // stdin/stdout mode
        if (parsed.opts.decompress) {
            try decompressStdin(allocator);
        } else {
            try compressStdin(allocator, parsed.opts);
        }
        return;
    }

    for (parsed.files) |path| {
        if (parsed.opts.recursive) {
            // Try to open as directory; if it fails with NotDir, process as file
            if (Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) |dir| {
                dir.close(io);
                try processDirectory(allocator, io, path, parsed.opts);
            } else |err| {
                if (err == error.NotDir) {
                    try processFile(allocator, io, path, parsed.opts);
                } else {
                    std.debug.print("zflate: can't open '{s}': {s}\n", .{ path, @errorName(err) });
                    std.process.exit(1);
                }
            }
        } else {
            try processFile(allocator, io, path, parsed.opts);
        }
    }
}
