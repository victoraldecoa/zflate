const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidData,
    InvalidHuffmanCode,
    InvalidBlockType,
    InvalidDistance,
    InvalidLength,
    CorruptInput,
    EndOfStream,
    AdlerMismatch,
    OutOfMemory,
};

// ============================================
// Adler-32
// ============================================
fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn adler32Update(state: u32, data: []const u8) u32 {
    var a = state & 0xFFFF;
    var b = state >> 16;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// ============================================
// CRC-32 (IEEE 802.3, used by gzip, PNG, etc.)
// ============================================
const crc32_table = blk: {
    @setEvalBranchQuota(100000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        var j: u8 = 0;
        while (j < 8) : (j += 1) {
            if ((crc & 1) != 0) {
                crc = 0xEDB88320 ^ (crc >> 1);
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc32_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// ============================================
// Bit utilities
// ============================================
inline fn reverseBits(code: u32, len: u5) u32 {
    var res: u32 = 0;
    var i: u5 = 0;
    var cc = code;
    while (i < len) : (i += 1) {
        res = (res << 1) | (cc & 1);
        cc >>= 1;
    }
    return res;
}

// ============================================
// BitReader
// ============================================
const BitReader = struct {
    buf: []const u8,
    pos: usize,
    bit_buf: u32,
    bit_count: u5,

    fn init(buf: []const u8) BitReader {
        return .{
            .buf = buf,
            .pos = 0,
            .bit_buf = 0,
            .bit_count = 0,
        };
    }

    fn ensureBits(self: *BitReader, n: u5) Error!void {
        while (self.bit_count < n) {
            if (self.pos >= self.buf.len) return error.EndOfStream;
            self.bit_buf |= @as(u32, self.buf[self.pos]) << self.bit_count;
            self.pos += 1;
            self.bit_count += 8;
        }
    }

    fn ensureBitsPad(self: *BitReader, n: u5) void {
        while (self.bit_count < n and self.pos < self.buf.len) {
            self.bit_buf |= @as(u32, self.buf[self.pos]) << self.bit_count;
            self.pos += 1;
            self.bit_count += 8;
        }
    }

    fn readBits(self: *BitReader, n: u5) Error!u32 {
        try self.ensureBits(n);
        const mask = if (n == 32) ~@as(u32, 0) else (@as(u32, 1) << n) - 1;
        const value = self.bit_buf & mask;
        self.bit_buf >>= n;
        self.bit_count -= n;
        return value;
    }

    fn readBit(self: *BitReader) Error!u1 {
        return @intCast(try self.readBits(1));
    }

    fn alignToByte(self: *BitReader) void {
        const discard = self.bit_count % 8;
        self.bit_buf >>= discard;
        self.bit_count -= discard;
    }

    fn readByte(self: *BitReader) Error!u8 {
        self.alignToByte();
        if (self.pos >= self.buf.len) return error.EndOfStream;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }
};

// ============================================
// BitWriter
// ============================================
pub const BitWriter = struct {
    list: std.ArrayList(u8),
    allocator: Allocator,
    bit_buf: u32,
    bit_count: u5,

    pub fn init(allocator: Allocator) BitWriter {
        return .{
            .list = std.ArrayList(u8).empty,
            .allocator = allocator,
            .bit_buf = 0,
            .bit_count = 0,
        };
    }

    pub fn deinit(self: *BitWriter) void {
        self.list.deinit(self.allocator);
    }

    inline fn writeBits(self: *BitWriter, n: u5, value: u32) Error!void {
        const mask = if (n == 32) ~@as(u32, 0) else (@as(u32, 1) << n) - 1;
        self.bit_buf |= (value & mask) << self.bit_count;
        self.bit_count += n;
        while (self.bit_count >= 8) {
            const byte: u8 = @truncate(self.bit_buf);
            self.list.append(self.allocator, byte) catch return error.OutOfMemory;
            self.bit_buf >>= 8;
            self.bit_count -= 8;
        }
    }

    inline fn writeBit(self: *BitWriter, bit: u1) Error!void {
        self.writeBits(1, bit) catch return error.OutOfMemory;
    }

    inline fn alignToByte(self: *BitWriter) Error!void {
        if (self.bit_count > 0) {
            const byte: u8 = @truncate(self.bit_buf);
            self.list.append(self.allocator, byte) catch return error.OutOfMemory;
            self.bit_buf = 0;
            self.bit_count = 0;
        }
    }

    inline fn writeByte(self: *BitWriter, byte: u8) Error!void {
        self.alignToByte() catch return error.OutOfMemory;
        self.list.append(self.allocator, byte) catch return error.OutOfMemory;
    }

    pub fn finish(self: *BitWriter) Error![]u8 {
        if (self.bit_count > 0) {
            const byte: u8 = @truncate(self.bit_buf);
            try self.list.append(self.allocator, byte);
            self.bit_buf = 0;
            self.bit_count = 0;
        }
        return self.list.toOwnedSlice(self.allocator);
    }
};

// ============================================
// Huffman
// ============================================
const MAX_HUFFMAN_BITS = 15;
const HUFFMAN_TABLE_SIZE = 1 << MAX_HUFFMAN_BITS;

const HuffmanTable = struct {
    lookup: [HUFFMAN_TABLE_SIZE]u16,

    fn initEmpty() HuffmanTable {
        return .{ .lookup = @splat(0) };
    }

    fn build(self: *HuffmanTable, lengths: []const u4) void {
        @setEvalBranchQuota(100000);
        @memset(&self.lookup, 0);
        var bl_count: [MAX_HUFFMAN_BITS + 1]u16 = @splat(0);
        for (lengths) |len| {
            if (len > 0) bl_count[len] += 1;
        }
        var next_code: [MAX_HUFFMAN_BITS + 1]u16 = undefined;
        var code: u16 = 0;
        bl_count[0] = 0;
        var bits: u5 = 1;
        while (bits <= MAX_HUFFMAN_BITS) : (bits += 1) {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }
        for (lengths, 0..) |len, sym| {
            if (len == 0) continue;
            const msb_code = next_code[len];
            next_code[len] += 1;
            const lsb_code = reverseBits(msb_code, len);
            const entry = (@as(u16, @intCast(sym)) << 4) | len;
            const step = @as(usize, 1) << len;
            var idx: usize = lsb_code;
            while (idx < HUFFMAN_TABLE_SIZE) : (idx += step) {
                self.lookup[idx] = entry;
            }
        }
    }

    fn decode(self: *const HuffmanTable, br: *BitReader) Error!u16 {
        br.ensureBitsPad(MAX_HUFFMAN_BITS);
        const lsb_bits = br.bit_buf & (HUFFMAN_TABLE_SIZE - 1);
        const entry = self.lookup[lsb_bits];
        const len: u5 = @truncate(entry & 0xF);
        if (len == 0) return error.InvalidHuffmanCode;
        br.bit_buf >>= len;
        br.bit_count -= len;
        return entry >> 4;
    }
};

// Precomputed fixed Huffman tables.
const fixed_lit_table = blk: {
    var table: HuffmanTable = undefined;
    var lengths: [288]u4 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    table.build(&lengths);
    break :blk table;
};

const fixed_dist_table = blk: {
    var table: HuffmanTable = undefined;
    var lengths: [32]u4 = undefined;
    for (&lengths) |*l| l.* = 5;
    table.build(&lengths);
    break :blk table;
};

// Precomputed fixed Huffman codes for encoding.
const fixed_lit_lengths = blk: {
    var lengths: [288]u4 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    break :blk lengths;
};

const fixed_lit_codes = blk: {
    var codes: [288]u16 = undefined;
    computeCodes(&fixed_lit_lengths, &codes);
    break :blk codes;
};

const fixed_dist_lengths = blk: {
    var lengths: [32]u4 = undefined;
    for (&lengths) |*l| l.* = 5;
    break :blk lengths;
};

const fixed_dist_codes = blk: {
    var codes: [32]u16 = undefined;
    computeCodes(&fixed_dist_lengths, &codes);
    break :blk codes;
};

// ============================================
// Length / Distance tables
// ============================================
const length_base = [_]u16{
    3,   4,   5,   6,   7,   8,  9,  10,
    11,  13,  15,  17,  19,  23, 27, 31,
    35,  43,  51,  59,  67,  83, 99, 115,
    131, 163, 195, 227, 258,
};
const length_extra_bits = [_]u5{
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0,
};
const distance_base = [_]u16{
    1,    2,    3,    4,     5,     7,     9,    13,
    17,   25,   33,   49,    65,    97,    129,  193,
    257,  385,  513,  769,   1025,  1537,  2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577,
};
const distance_extra_bits = [_]u5{
    0,  0,  0,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,
    7,  7,  8,  8,  9,  9,  10, 10,
    11, 11, 12, 12, 13, 13,
};

// ============================================
// Inflate helpers
// ============================================
fn inflateStored(br: *BitReader, allocator: Allocator, out: *std.ArrayList(u8)) Error!void {
    br.alignToByte();
    const len = try br.readBits(16);
    const nlen = try br.readBits(16);
    if (len != (~nlen & 0xFFFF)) return error.CorruptInput;
    if (br.pos + len > br.buf.len) return error.EndOfStream;
    try out.appendSlice(allocator, br.buf[br.pos .. br.pos + len]);
    br.pos += len;
}

fn copyFromOutput(allocator: Allocator, out: *std.ArrayList(u8), dist: u16, len: u16) Error!void {
    if (dist > out.items.len) return error.InvalidDistance;
    const old_len = out.items.len;
    const slice = try out.addManyAsSlice(allocator, len);
    for (0..len) |i| {
        slice[i] = out.items[old_len + i - dist];
    }
}

fn inflateBlockData(br: *BitReader, allocator: Allocator, out: *std.ArrayList(u8), lit_table: *const HuffmanTable, dist_table: *const HuffmanTable) Error!void {
    while (true) {
        const sym = try lit_table.decode(br);
        if (sym < 256) {
            try out.append(allocator, @truncate(sym));
        } else if (sym == 256) {
            break;
        } else {
            const len_code = sym - 257;
            var len = length_base[len_code];
            const extra_len_bits = length_extra_bits[len_code];
            if (extra_len_bits > 0) {
                const extra = try br.readBits(extra_len_bits);
                len += @intCast(extra);
            }
            const dist_sym = try dist_table.decode(br);
            var dist = distance_base[dist_sym];
            const extra_dist_bits = distance_extra_bits[dist_sym];
            if (extra_dist_bits > 0) {
                const extra = try br.readBits(extra_dist_bits);
                dist += @intCast(extra);
            }
            try copyFromOutput(allocator, out, dist, len);
        }
    }
}

fn inflateFixed(br: *BitReader, allocator: Allocator, out: *std.ArrayList(u8)) Error!void {
    try inflateBlockData(br, allocator, out, &fixed_lit_table, &fixed_dist_table);
}

fn inflateDynamic(br: *BitReader, allocator: Allocator, out: *std.ArrayList(u8)) Error!void {
    const num_lit = try br.readBits(5) + 257;
    const num_dist = try br.readBits(5) + 1;
    const num_clen = try br.readBits(4) + 4;

    const clen_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var clen_lengths: [19]u4 = @splat(0);
    for (0..num_clen) |i| {
        clen_lengths[clen_order[i]] = @intCast(try br.readBits(3));
    }

    var clen_table: HuffmanTable = .initEmpty();
    clen_table.build(&clen_lengths);

    var all_lengths = try allocator.alloc(u4, num_lit + num_dist);
    defer allocator.free(all_lengths);
    var idx: usize = 0;
    while (idx < num_lit + num_dist) {
        const sym = try clen_table.decode(br);
        if (sym <= 15) {
            all_lengths[idx] = @intCast(sym);
            idx += 1;
        } else if (sym == 16) {
            const repeat = 3 + @as(usize, @intCast(try br.readBits(2)));
            if (idx == 0) return error.InvalidData;
            const prev = all_lengths[idx - 1];
            for (0..repeat) |_| {
                all_lengths[idx] = prev;
                idx += 1;
            }
        } else if (sym == 17) {
            const repeat = 3 + @as(usize, @intCast(try br.readBits(3)));
            for (0..repeat) |_| {
                all_lengths[idx] = 0;
                idx += 1;
            }
        } else if (sym == 18) {
            const repeat = 11 + @as(usize, @intCast(try br.readBits(7)));
            for (0..repeat) |_| {
                all_lengths[idx] = 0;
                idx += 1;
            }
        } else {
            return error.InvalidData;
        }
    }

    var lit_table: HuffmanTable = .initEmpty();
    var dist_table: HuffmanTable = .initEmpty();
    lit_table.build(all_lengths[0..num_lit]);
    dist_table.build(all_lengths[num_lit..]);

    try inflateBlockData(br, allocator, out, &lit_table, &dist_table);
}

pub fn inflate(allocator: Allocator, input: []const u8) Error![]u8 {
    var br = BitReader.init(input);
    const cmf = try br.readByte();
    const flg = try br.readByte();
    if ((cmf & 0x0F) != 8) return error.InvalidData;
    if (((@as(u16, cmf) << 8) | flg) % 31 != 0) return error.InvalidData;
    if ((flg & 0x20) != 0) {
        _ = try br.readByte();
        _ = try br.readByte();
        _ = try br.readByte();
        _ = try br.readByte();
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var bfinal: u1 = 0;
    while (bfinal == 0) {
        bfinal = try br.readBit();
        const btype = try br.readBits(2);
        switch (btype) {
            0 => try inflateStored(&br, allocator, &out),
            1 => try inflateFixed(&br, allocator, &out),
            2 => try inflateDynamic(&br, allocator, &out),
            3 => return error.InvalidBlockType,
            else => unreachable,
        }
    }

    if (br.buf.len < 4) return error.EndOfStream;
    const adler = (@as(u32, br.buf[br.buf.len - 4]) << 24) |
        (@as(u32, br.buf[br.buf.len - 3]) << 16) |
        (@as(u32, br.buf[br.buf.len - 2]) << 8) |
        (@as(u32, br.buf[br.buf.len - 1]));

    const computed = adler32(out.items);
    if (adler != computed) return error.AdlerMismatch;

    return out.toOwnedSlice(allocator);
}

// ============================================
// Deflate helpers
// ============================================
const WINDOW_SIZE = 32768;
const HASH_BITS = 15;
const MAX_MATCH = 258;
const MIN_MATCH = 3;

const Matcher = struct {
    prev: []i32,
    head: []i32,
    window_size: u32,
    hash_size: u32,

    fn init(allocator: Allocator, window_size: u32, hash_bits: u5) !Matcher {
        const hash_size = @as(u32, 1) << hash_bits;
        const self = Matcher{
            .prev = try allocator.alloc(i32, window_size),
            .head = try allocator.alloc(i32, hash_size),
            .window_size = window_size,
            .hash_size = hash_size,
        };
        @memset(self.prev, -1);
        @memset(self.head, -1);
        return self;
    }

    fn deinit(self: *Matcher, allocator: Allocator) void {
        allocator.free(self.prev);
        allocator.free(self.head);
    }

    fn hash(self: *const Matcher, b0: u8, b1: u8, b2: u8) u32 {
        var h: u32 = b0;
        h = ((h << 5) ^ b1);
        h = ((h << 5) ^ b2);
        return h & (self.hash_size - 1);
    }

    fn findMatch(self: *Matcher, src: []const u8, pos: usize) struct { len: u16, dist: u16 } {
        if (pos + MIN_MATCH > src.len) return .{ .len = 0, .dist = 0 };
        const b0 = src[pos];
        const b1 = src[pos + 1];
        const b2 = src[pos + 2];
        const b3 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16);
        const h = self.hash(b0, b1, b2);
        var best_len: u16 = 0;
        var best_dist: u16 = 0;
        var chain_len: u32 = 0;
        var max_chain: u32 = 256;
        if (pos >= 4096) max_chain = 128;
        if (pos >= self.window_size) max_chain = 64;
        var prev_pos = self.head[h];
        while (prev_pos >= 0 and chain_len < max_chain) {
            const p = @as(usize, @intCast(prev_pos));
            const dist = pos - p;
            if (dist == 0 or dist > self.window_size) break;
            const a3_ptr: *align(1) const u32 = @ptrCast(&src[p]);
            if ((a3_ptr.* & 0xFFFFFF) == b3) {
                var len: u16 = 3;
                const remaining = src.len - pos;
                const limit: u16 = if (remaining >= MAX_MATCH) MAX_MATCH else @intCast(remaining);
                while (len + 4 <= limit) {
                    const a_ptr: *align(1) const u32 = @ptrCast(&src[p + len]);
                    const b_ptr: *align(1) const u32 = @ptrCast(&src[pos + len]);
                    if (a_ptr.* != b_ptr.*) break;
                    len += 4;
                }
                while (len < limit and src[p + len] == src[pos + len]) {
                    len += 1;
                }
                if (len > best_len) {
                    best_len = len;
                    best_dist = @intCast(dist);
                    if (len == MAX_MATCH) break;
                }
            }
            prev_pos = self.prev[p % self.window_size];
            chain_len += 1;
        }
        return .{ .len = best_len, .dist = best_dist };
    }

    fn slide(self: *Matcher, src: []const u8, pos: usize) void {
        if (pos + 2 < src.len) {
            const h = self.hash(src[pos], src[pos + 1], src[pos + 2]);
            self.prev[pos % self.window_size] = self.head[h];
            self.head[h] = @intCast(pos);
        }
    }
};

inline fn encodeLength(len: u16) u16 {
    if (len <= 10) return 254 + len;
    if (len <= 12) return 265;
    if (len <= 14) return 266;
    if (len <= 16) return 267;
    if (len <= 18) return 268;
    if (len <= 22) return 269;
    if (len <= 26) return 270;
    if (len <= 30) return 271;
    if (len <= 34) return 272;
    if (len <= 42) return 273;
    if (len <= 50) return 274;
    if (len <= 58) return 275;
    if (len <= 66) return 276;
    if (len <= 82) return 277;
    if (len <= 98) return 278;
    if (len <= 114) return 279;
    if (len <= 130) return 280;
    if (len <= 162) return 281;
    if (len <= 194) return 282;
    if (len <= 226) return 283;
    if (len <= 257) return 284;
    return 285;
}

inline fn encodeDistance(dist: u16) u16 {
    if (dist <= 4) return dist - 1;
    if (dist <= 6) return 4;
    if (dist <= 8) return 5;
    if (dist <= 12) return 6;
    if (dist <= 16) return 7;
    if (dist <= 24) return 8;
    if (dist <= 32) return 9;
    if (dist <= 48) return 10;
    if (dist <= 64) return 11;
    if (dist <= 96) return 12;
    if (dist <= 128) return 13;
    if (dist <= 192) return 14;
    if (dist <= 256) return 15;
    if (dist <= 384) return 16;
    if (dist <= 512) return 17;
    if (dist <= 768) return 18;
    if (dist <= 1024) return 19;
    if (dist <= 1536) return 20;
    if (dist <= 2048) return 21;
    if (dist <= 3072) return 22;
    if (dist <= 4096) return 23;
    if (dist <= 6144) return 24;
    if (dist <= 8192) return 25;
    if (dist <= 12288) return 26;
    if (dist <= 16384) return 27;
    if (dist <= 24576) return 28;
    return 29;
}

fn computeCodes(lengths: []const u4, codes: []u16) void {
    @memset(codes, 0);
    var bl_count: [16]u16 = @splat(0);
    for (lengths) |len| {
        if (len > 0) bl_count[len] += 1;
    }
    var next_code: [16]u16 = undefined;
    var code: u16 = 0;
    bl_count[0] = 0;
    var bits: u5 = 1;
    while (bits <= 15) : (bits += 1) {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }
    for (lengths, 0..) |len, sym| {
        if (len != 0) {
            codes[sym] = next_code[len];
            next_code[len] += 1;
        }
    }
}

fn buildHuffmanLengths(freqs: []const u32, max_bits: u5, lengths: []u4) void {
    @memset(lengths, 0);
    var num_used: usize = 0;
    for (freqs) |f| {
        if (f > 0) num_used += 1;
    }
    if (num_used == 0) {
        return;
    }
    if (num_used == 1) {
        for (freqs, 0..) |f, i| {
            if (f > 0) {
                lengths[i] = 1;
                return;
            }
        }
    }

    var adj_freq: [320]u64 = @splat(0);
    for (freqs, 0..) |f, i| {
        adj_freq[i] = f;
    }

    const Node = struct {
        freq: u64,
        is_node: bool,
        left: u16,
        right: u16,
        sym: u16,
    };

    var depths: [320]u16 = @splat(0);

    while (true) {
        var tree: [640]Node = undefined;
        var num_tree: usize = 0;
        for (adj_freq, 0..) |f, sym| {
            if (f > 0) {
                tree[num_tree] = .{
                    .freq = f,
                    .is_node = false,
                    .left = 0,
                    .right = 0,
                    .sym = @intCast(sym),
                };
                num_tree += 1;
            }
        }

        var heap: [640]u16 = undefined;
        var heap_len: usize = num_tree;
        for (0..num_tree) |j| heap[j] = @intCast(j);

        // Heapify
        var h: usize = num_tree / 2;
        while (h > 0) {
            h -= 1;
            var parent = h;
            while (true) {
                const left = parent * 2 + 1;
                const right = left + 1;
                var smallest = parent;
                if (left < heap_len and tree[heap[left]].freq < tree[heap[smallest]].freq) smallest = left;
                if (right < heap_len and tree[heap[right]].freq < tree[heap[smallest]].freq) smallest = right;
                if (smallest == parent) break;
                const tmp = heap[parent];
                heap[parent] = heap[smallest];
                heap[smallest] = tmp;
                parent = smallest;
            }
        }

        while (heap_len > 1) {
            // Pop min1
            const left = heap[0];
            heap[0] = heap[heap_len - 1];
            heap_len -= 1;
            var parent: usize = 0;
            while (true) {
                const l = parent * 2 + 1;
                const r = l + 1;
                var smallest = parent;
                if (l < heap_len and tree[heap[l]].freq < tree[heap[smallest]].freq) smallest = l;
                if (r < heap_len and tree[heap[r]].freq < tree[heap[smallest]].freq) smallest = r;
                if (smallest == parent) break;
                const tmp = heap[parent];
                heap[parent] = heap[smallest];
                heap[smallest] = tmp;
                parent = smallest;
            }

            // Pop min2
            const right = heap[0];
            heap[0] = heap[heap_len - 1];
            heap_len -= 1;
            parent = 0;
            while (true) {
                const l = parent * 2 + 1;
                const r = l + 1;
                var smallest = parent;
                if (l < heap_len and tree[heap[l]].freq < tree[heap[smallest]].freq) smallest = l;
                if (r < heap_len and tree[heap[r]].freq < tree[heap[smallest]].freq) smallest = r;
                if (smallest == parent) break;
                const tmp = heap[parent];
                heap[parent] = heap[smallest];
                heap[smallest] = tmp;
                parent = smallest;
            }

            tree[num_tree] = .{
                .freq = tree[left].freq + tree[right].freq,
                .is_node = true,
                .left = left,
                .right = right,
                .sym = 0,
            };
            heap[heap_len] = @intCast(num_tree);
            heap_len += 1;
            // sift up
            var child = heap_len - 1;
            while (child > 0) {
                const p = (child - 1) / 2;
                if (tree[heap[p]].freq <= tree[heap[child]].freq) break;
                const tmp = heap[p];
                heap[p] = heap[child];
                heap[child] = tmp;
                child = p;
            }
            num_tree += 1;
        }

        const root = heap[0];
        var stack: [640]u16 = undefined;
        var depth_stack: [640]u16 = undefined;
        var stack_len: usize = 0;
        stack[stack_len] = root;
        depth_stack[stack_len] = 0;
        stack_len += 1;
        var max_depth: u16 = 0;
        @memset(&depths, 0);
        while (stack_len > 0) {
            stack_len -= 1;
            const idx = stack[stack_len];
            const depth = depth_stack[stack_len];
            const node = tree[idx];
            if (!node.is_node) {
                depths[node.sym] = depth;
                if (depth > max_depth) max_depth = depth;
            } else {
                stack[stack_len] = node.right;
                depth_stack[stack_len] = depth + 1;
                stack_len += 1;
                stack[stack_len] = node.left;
                depth_stack[stack_len] = depth + 1;
                stack_len += 1;
            }
        }

        if (max_depth <= max_bits) {
            for (0..freqs.len) |sym| {
                const d = depths[sym];
                if (d > 0) lengths[sym] = @intCast(d);
            }
            return;
        }

        var deepest_syms: [320]u16 = undefined;
        var num_deepest: usize = 0;
        for (0..freqs.len) |sym| {
            const d = depths[sym];
            if (d == max_depth and freqs[sym] > 0) {
                deepest_syms[num_deepest] = @intCast(sym);
                num_deepest += 1;
            }
        }
        for (0..num_deepest) |j| {
            adj_freq[deepest_syms[j]] += 1;
        }
    }
}

pub fn deflateDynamicBlock(bw: *BitWriter, matcher: *Matcher, src: []const u8, start: usize, end: usize, bfinal: u1) Error!void {
    const Token = struct {
        symbol: u16, // 0-255 = literal, 3-258 = match length
        dist: u16, // 0 = literal, >0 = distance
    };

    const block_len = end - start;
    var tokens = try bw.allocator.alloc(Token, block_len + 1);
    defer bw.allocator.free(tokens);
    var num_tokens: usize = 0;

    var lit_freq: [288]u32 = @splat(0);
    var dist_freq: [32]u32 = @splat(0);
    var pos = start;
    while (pos < end) {
        const match = matcher.findMatch(src, pos);
        const max_len = end - pos;
        const effective_len = if (max_len >= match.len) match.len else @as(u16, @intCast(max_len));
        if (effective_len >= MIN_MATCH) {
            const len_code = encodeLength(effective_len);
            lit_freq[len_code] += 1;
            const dist_code = encodeDistance(match.dist);
            dist_freq[dist_code] += 1;
            tokens[num_tokens] = .{ .symbol = effective_len, .dist = match.dist };
            num_tokens += 1;
            var i: usize = 0;
            while (i < effective_len) : (i += 1) {
                matcher.slide(src, pos + i);
            }
            pos += effective_len;
        } else {
            lit_freq[src[pos]] += 1;
            tokens[num_tokens] = .{ .symbol = src[pos], .dist = 0 };
            num_tokens += 1;
            matcher.slide(src, pos);
            pos += 1;
        }
    }
    lit_freq[256] += 1;

    var lit_lengths: [288]u4 = undefined;
    var dist_lengths: [32]u4 = undefined;
    buildHuffmanLengths(&lit_freq, 15, &lit_lengths);
    buildHuffmanLengths(&dist_freq, 15, &dist_lengths);

    var lit_codes: [288]u16 = undefined;
    var dist_codes: [32]u16 = undefined;
    computeCodes(&lit_lengths, &lit_codes);
    computeCodes(&dist_lengths, &dist_codes);

    var num_lit: usize = 288;
    while (num_lit > 257 and lit_lengths[num_lit - 1] == 0) {
        num_lit -= 1;
    }
    var num_dist: usize = 32;
    while (num_dist > 2 and dist_lengths[num_dist - 1] == 0) {
        num_dist -= 1;
    }
    if (num_dist == 0) num_dist = 1;

    const clen_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var all_lengths: [288 + 32]u4 = undefined;
    @memcpy(all_lengths[0..num_lit], lit_lengths[0..num_lit]);
    @memcpy(all_lengths[num_lit..][0..num_dist], dist_lengths[0..num_dist]);

    var clen_freq: [19]u32 = @splat(0);
    var clen_symbols: [2 * (288 + 32)]u16 = undefined;
    var clen_idx: usize = 0;
    var i: usize = 0;
    while (i < num_lit + num_dist) {
        const len = all_lengths[i];
        if (len == 0) {
            var run: usize = 1;
            i += 1;
            while (i < num_lit + num_dist and all_lengths[i] == 0 and run < 138) {
                run += 1;
                i += 1;
            }
            if (run >= 11) {
                clen_symbols[clen_idx] = 18;
                clen_idx += 1;
                clen_symbols[clen_idx] = @intCast(run - 11);
                clen_idx += 1;
                clen_freq[18] += 1;
            } else if (run >= 3) {
                clen_symbols[clen_idx] = 17;
                clen_idx += 1;
                clen_symbols[clen_idx] = @intCast(run - 3);
                clen_idx += 1;
                clen_freq[17] += 1;
            } else {
                for (0..run) |_| {
                    clen_symbols[clen_idx] = 0;
                    clen_idx += 1;
                    clen_freq[0] += 1;
                }
            }
        } else {
            if (i > 0 and all_lengths[i] == all_lengths[i - 1]) {
                var run: usize = 1;
                i += 1;
                while (i < num_lit + num_dist and all_lengths[i] == len and run < 6) {
                    run += 1;
                    i += 1;
                }
                if (run >= 3) {
                    clen_symbols[clen_idx] = 16;
                    clen_idx += 1;
                    clen_symbols[clen_idx] = @intCast(run - 3);
                    clen_idx += 1;
                    clen_freq[16] += 1;
                } else {
                    for (0..run) |_| {
                        clen_symbols[clen_idx] = len;
                        clen_idx += 1;
                        clen_freq[len] += 1;
                    }
                }
            } else {
                clen_symbols[clen_idx] = len;
                clen_idx += 1;
                clen_freq[len] += 1;
                i += 1;
            }
        }
    }

    var clen_lengths: [19]u4 = undefined;
    buildHuffmanLengths(&clen_freq, 7, &clen_lengths);
    var clen_codes: [19]u16 = undefined;
    computeCodes(&clen_lengths, &clen_codes);

    var num_clen: usize = 19;
    while (num_clen > 4 and clen_lengths[clen_order[num_clen - 1]] == 0) {
        num_clen -= 1;
    }
    try bw.writeBit(bfinal);
    try bw.writeBits(2, 2);
    try bw.writeBits(5, @intCast(num_lit - 257));
    try bw.writeBits(5, @intCast(num_dist - 1));
    try bw.writeBits(4, @intCast(num_clen - 4));

    for (0..num_clen) |j| {
        const s = clen_order[j];
        const len = clen_lengths[s];
        try bw.writeBits(3, len);
    }

    var k: usize = 0;
    while (k < clen_idx) {
        const sym = clen_symbols[k];
        k += 1;
        const code_len = clen_lengths[sym];
        const code = clen_codes[sym];
        try bw.writeBits(code_len, reverseBits(code, code_len));
        switch (sym) {
            16 => {
                const extra = clen_symbols[k];
                k += 1;
                try bw.writeBits(2, extra);
            },
            17 => {
                const extra = clen_symbols[k];
                k += 1;
                try bw.writeBits(3, extra);
            },
            18 => {
                const extra = clen_symbols[k];
                k += 1;
                try bw.writeBits(7, extra);
            },
            else => {},
        }
    }

    for (0..num_tokens) |t| {
        const tok = tokens[t];
        if (tok.dist == 0) {
            const byte = @as(u8, @intCast(tok.symbol));
            try bw.writeBits(lit_lengths[byte], reverseBits(lit_codes[byte], lit_lengths[byte]));
        } else {
            const match_len = tok.symbol;
            const match_dist = tok.dist;
            const len_code = encodeLength(match_len);
            const len_extra = length_extra_bits[len_code - 257];
            const len_base_val = length_base[len_code - 257];
            const len_extra_val = match_len - len_base_val;
            try bw.writeBits(lit_lengths[len_code], reverseBits(lit_codes[len_code], lit_lengths[len_code]));
            if (len_extra > 0) try bw.writeBits(len_extra, len_extra_val);

            const dist_code = encodeDistance(match_dist);
            const dist_extra = distance_extra_bits[dist_code];
            const dist_base_val = distance_base[dist_code];
            const dist_extra_val = match_dist - dist_base_val;
            try bw.writeBits(dist_lengths[dist_code], reverseBits(dist_codes[dist_code], dist_lengths[dist_code]));
            if (dist_extra > 0) try bw.writeBits(dist_extra, dist_extra_val);
        }
    }
    try bw.writeBits(lit_lengths[256], reverseBits(lit_codes[256], lit_lengths[256]));
}

fn deflateStoredBlock(bw: *BitWriter, input: []const u8, bfinal: u1) Error!void {
    try bw.writeBit(bfinal);
    try bw.writeBits(2, 0);
    try bw.alignToByte();
    const len: u16 = @intCast(input.len);
    const nlen: u16 = ~len;
    try bw.writeBits(16, len);
    try bw.writeBits(16, nlen);
    for (input) |byte| {
        try bw.list.append(bw.allocator, byte);
    }
}

pub const CompressionLevel = enum {
    store, // no compression
    fast, // speed optimized
    default, // balanced
    best, // ratio optimized
};

fn deflateFixedBlock(bw: *BitWriter, matcher: *Matcher, src: []const u8, start: usize, end: usize, bfinal: u1) Error!void {
    try bw.writeBit(bfinal);
    try bw.writeBits(2, 1);

    var pos = start;
    while (pos < end) {
        const match = matcher.findMatch(src, pos);
        const max_len = end - pos;
        const effective_len = if (max_len >= match.len) match.len else @as(u16, @intCast(max_len));
        if (effective_len >= MIN_MATCH) {
            const len_code = encodeLength(effective_len);
            const len_extra = length_extra_bits[len_code - 257];
            const len_base_val = length_base[len_code - 257];
            const len_extra_val = effective_len - len_base_val;
            try bw.writeBits(fixed_lit_lengths[len_code], reverseBits(fixed_lit_codes[len_code], fixed_lit_lengths[len_code]));
            if (len_extra > 0) try bw.writeBits(len_extra, len_extra_val);

            const dist_code = encodeDistance(match.dist);
            const dist_extra = distance_extra_bits[dist_code];
            const dist_base_val = distance_base[dist_code];
            const dist_extra_val = match.dist - dist_base_val;
            try bw.writeBits(fixed_dist_lengths[dist_code], reverseBits(fixed_dist_codes[dist_code], fixed_dist_lengths[dist_code]));
            if (dist_extra > 0) try bw.writeBits(dist_extra, dist_extra_val);

            var i: usize = 0;
            while (i < effective_len) : (i += 1) {
                matcher.slide(src, pos + i);
            }
            pos += effective_len;
        } else {
            try bw.writeBits(fixed_lit_lengths[src[pos]], reverseBits(fixed_lit_codes[src[pos]], fixed_lit_lengths[src[pos]]));
            matcher.slide(src, pos);
            pos += 1;
        }
    }
    try bw.writeBits(fixed_lit_lengths[256], reverseBits(fixed_lit_codes[256], fixed_lit_lengths[256]));
}

fn deflateBlock(bw: *BitWriter, matcher: *Matcher, src: []const u8, start: usize, end: usize, bfinal: u1, level: CompressionLevel) Error!void {
    const len = end - start;
    if (level == .store or len < 32) {
        try deflateStoredBlock(bw, src[start..end], bfinal);
        return;
    }
    // For small inputs, fixed Huffman can be better than dynamic.
    // For larger inputs, dynamic is almost always better.
    // Use a simple heuristic: if input < 256 bytes, try fixed.
    if (len < 256) {
        try deflateFixedBlock(bw, matcher, src, start, end, bfinal);
    } else {
        try deflateDynamicBlock(bw, matcher, src, start, end, bfinal);
    }
}

fn deflateBlocks(bw: *BitWriter, input: []const u8, level: CompressionLevel, small: bool) Error!void {
    if (input.len == 0) {
        // Emit an empty stored block for empty input.
        try deflateStoredBlock(bw, input, 1);
        return;
    }
    // Use larger blocks for better compression ratio. For inputs up to 128KB,
    // use a single block to avoid block-boundary overhead. For larger inputs,
    // use 128KB blocks.
    const BLOCK_SIZE: usize = if (input.len <= 128 * 1024) input.len else 131072;
    const window_size: u32 = if (small) 4096 else WINDOW_SIZE;
    const hash_bits: u5 = if (small) 13 else HASH_BITS;
    var matcher = try Matcher.init(bw.allocator, window_size, hash_bits);
    defer matcher.deinit(bw.allocator);
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + BLOCK_SIZE, input.len);
        const is_last = end == input.len;
        const bfinal: u1 = if (is_last) 1 else 0;
        try deflateBlock(bw, &matcher, input, offset, end, bfinal, level);
        offset = end;
    }
}

pub const DeflateOptions = struct {
    level: CompressionLevel = .default,
    small: bool = false,
};

pub fn deflate(allocator: Allocator, input: []const u8) Error![]u8 {
    return deflateWithOptions(allocator, input, .{});
}

pub fn deflateWithLevel(allocator: Allocator, input: []const u8, level: CompressionLevel) Error![]u8 {
    return deflateWithOptions(allocator, input, .{ .level = level });
}

pub fn deflateWithOptions(allocator: Allocator, input: []const u8, options: DeflateOptions) Error![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try bw.list.ensureTotalCapacity(allocator, input.len + 6);

    try bw.writeByte(0x78);
    try bw.writeByte(0x9C);

    try deflateBlocks(&bw, input, options.level, options.small);

    const compressed = try bw.finish();

    const adler = adler32(input);
    const final = try allocator.realloc(compressed, compressed.len + 4);
    final[compressed.len + 0] = @truncate(adler >> 24);
    final[compressed.len + 1] = @truncate(adler >> 16);
    final[compressed.len + 2] = @truncate(adler >> 8);
    final[compressed.len + 3] = @truncate(adler);
    return final;
}

pub fn deflateRaw(allocator: Allocator, input: []const u8) Error![]u8 {
    return deflateRawWithOptions(allocator, input, .{});
}

pub fn deflateRawWithLevel(allocator: Allocator, input: []const u8, level: CompressionLevel) Error![]u8 {
    return deflateRawWithOptions(allocator, input, .{ .level = level });
}

pub fn deflateRawWithOptions(allocator: Allocator, input: []const u8, options: DeflateOptions) Error![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try bw.list.ensureTotalCapacity(allocator, input.len + 4);

    try deflateBlocks(&bw, input, options.level, options.small);

    return bw.finish();
}

pub fn inflateRaw(allocator: Allocator, input: []const u8) Error![]u8 {
    var br = BitReader.init(input);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var bfinal: u1 = 0;
    while (bfinal == 0) {
        bfinal = try br.readBit();
        const btype = try br.readBits(2);
        switch (btype) {
            0 => try inflateStored(&br, allocator, &out),
            1 => try inflateFixed(&br, allocator, &out),
            2 => try inflateDynamic(&br, allocator, &out),
            3 => return error.InvalidBlockType,
            else => unreachable,
        }
    }
    return out.toOwnedSlice(allocator);
}

// ============================================
// Gzip format
// ============================================

pub fn gzipCompress(allocator: Allocator, input: []const u8, filename: ?[]const u8, level: CompressionLevel) Error![]u8 {
    return gzipCompressWithOptions(allocator, input, filename, .{ .level = level });
}

pub fn gzipCompressWithOptions(allocator: Allocator, input: []const u8, filename: ?[]const u8, options: DeflateOptions) Error![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try bw.list.ensureTotalCapacity(allocator, input.len + 128);

    // Gzip header
    try bw.writeByte(0x1f); // ID1
    try bw.writeByte(0x8b); // ID2
    try bw.writeByte(8); // CM = deflate
    var flg: u8 = 0;
    if (filename != null) flg |= 0x08; // FNAME
    try bw.writeByte(flg);
    try bw.writeByte(0); // MTIME (4 bytes, 0 = no timestamp)
    try bw.writeByte(0);
    try bw.writeByte(0);
    try bw.writeByte(0);
    try bw.writeByte(0); // XFL
    try bw.writeByte(3); // OS = Unix
    if (filename) |name| {
        for (name) |byte| {
            try bw.writeByte(byte);
        }
        try bw.writeByte(0);
    }

    // Deflate data (raw, no zlib wrapper)
    try deflateBlocks(&bw, input, options.level, options.small);
    try bw.alignToByte();
    const compressed_len = bw.list.items.len;

    // CRC32 and ISIZE trailer (little-endian)
    const crc_val = crc32(input);
    const in_size: u32 = @truncate(input.len);

    var result = try allocator.alloc(u8, compressed_len + 8);
    @memcpy(result[0..compressed_len], bw.list.items);
    bw.list.deinit(allocator);
    result[compressed_len + 0] = @truncate(crc_val);
    result[compressed_len + 1] = @truncate(crc_val >> 8);
    result[compressed_len + 2] = @truncate(crc_val >> 16);
    result[compressed_len + 3] = @truncate(crc_val >> 24);
    result[compressed_len + 4] = @truncate(in_size);
    result[compressed_len + 5] = @truncate(in_size >> 8);
    result[compressed_len + 6] = @truncate(in_size >> 16);
    result[compressed_len + 7] = @truncate(in_size >> 24);
    return result;
}

pub fn gzipDecompress(allocator: Allocator, input: []const u8) Error!struct { data: []u8, filename: ?[]const u8 } {
    var br = BitReader.init(input);

    if (try br.readByte() != 0x1f) return error.InvalidData;
    if (try br.readByte() != 0x8b) return error.InvalidData;
    if (try br.readByte() != 8) return error.InvalidData;
    const flg = try br.readByte();
    // Skip MTIME, XFL, OS
    _ = try br.readByte();
    _ = try br.readByte();
    _ = try br.readByte();
    _ = try br.readByte();
    _ = try br.readByte();
    _ = try br.readByte();

    if ((flg & 0x04) != 0) { // FEXTRA
        const xlen = try br.readByte() | (@as(u16, try br.readByte()) << 8);
        var i: u16 = 0;
        while (i < xlen) : (i += 1) {
            _ = try br.readByte();
        }
    }

    var filename: ?[]u8 = null;
    if ((flg & 0x08) != 0) { // FNAME
        var name_list = std.ArrayList(u8).empty;
        errdefer if (filename) |f| allocator.free(f);
        while (true) {
            const byte = try br.readByte();
            if (byte == 0) break;
            try name_list.append(allocator, byte);
        }
        filename = try name_list.toOwnedSlice(allocator);
    }

    if ((flg & 0x10) != 0) { // FCOMMENT
        while (true) {
            const byte = try br.readByte();
            if (byte == 0) break;
        }
    }
    if ((flg & 0x02) != 0) { // FHCRC
        _ = try br.readByte();
        _ = try br.readByte();
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var bfinal: u1 = 0;
    while (bfinal == 0) {
        bfinal = try br.readBit();
        const btype = try br.readBits(2);
        switch (btype) {
            0 => try inflateStored(&br, allocator, &out),
            1 => try inflateFixed(&br, allocator, &out),
            2 => try inflateDynamic(&br, allocator, &out),
            3 => return error.InvalidBlockType,
            else => unreachable,
        }
    }

    // Read trailer (always the last 8 bytes in a well-formed gzip file)
    const data = out.items;
    if (input.len < 8) return error.InvalidData;
    const trailer_start = input.len - 8;
    const stored_crc = @as(u32, input[trailer_start]) |
        (@as(u32, input[trailer_start + 1]) << 8) |
        (@as(u32, input[trailer_start + 2]) << 16) |
        (@as(u32, input[trailer_start + 3]) << 24);
    const stored_isize = @as(u32, input[trailer_start + 4]) |
        (@as(u32, input[trailer_start + 5]) << 8) |
        (@as(u32, input[trailer_start + 6]) << 16) |
        (@as(u32, input[trailer_start + 7]) << 24);

    if (stored_isize != @as(u32, @truncate(data.len))) return error.InvalidData;
    const computed_crc = crc32(data);
    if (stored_crc != computed_crc) return error.InvalidData;

    return .{ .data = try out.toOwnedSlice(allocator), .filename = filename };
}

// ============================================
// Streaming API
// ============================================

pub const Compressor = struct {
    allocator: Allocator,
    level: CompressionLevel,
    small: bool,
    bw: BitWriter,
    buffer: std.ArrayList(u8),
    adler: u32,

    pub fn init(allocator: Allocator, level: CompressionLevel) Error!Compressor {
        return initWithOptions(allocator, .{ .level = level });
    }

    pub fn initWithOptions(allocator: Allocator, options: DeflateOptions) Error!Compressor {
        var bw = BitWriter.init(allocator);
        try bw.writeByte(0x78);
        try bw.writeByte(0x9C);
        return .{
            .allocator = allocator,
            .level = options.level,
            .small = options.small,
            .bw = bw,
            .buffer = std.ArrayList(u8).empty,
            .adler = 1,
        };
    }

    pub fn deinit(self: *Compressor) void {
        self.bw.deinit();
        self.buffer.deinit(self.allocator);
    }

    pub fn write(self: *Compressor, chunk: []const u8) Error!void {
        try self.buffer.appendSlice(self.allocator, chunk);
        self.adler = adler32Update(self.adler, chunk);
    }

    pub fn finish(self: *Compressor) Error![]u8 {
        try deflateBlocks(&self.bw, self.buffer.items, self.level, self.small);
        const compressed = try self.bw.finish();
        const final = try self.allocator.realloc(compressed, compressed.len + 4);
        final[compressed.len + 0] = @truncate(self.adler >> 24);
        final[compressed.len + 1] = @truncate(self.adler >> 16);
        final[compressed.len + 2] = @truncate(self.adler >> 8);
        final[compressed.len + 3] = @truncate(self.adler);
        return final;
    }
};

pub const Decompressor = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Decompressor {
        return .{ .allocator = allocator };
    }

    pub fn decompress(self: *Decompressor, input: []const u8) Error![]u8 {
        return inflate(self.allocator, input);
    }

    pub fn decompressRaw(self: *Decompressor, input: []const u8) Error![]u8 {
        return inflateRaw(self.allocator, input);
    }
};

// ============================================
// Tests
// ============================================
const c = struct {
    pub const Z_OK = 0;
    pub extern "c" fn compressBound(sourceLen: c_ulong) c_ulong;
    pub extern "c" fn compress(dest: [*]u8, destLen: *c_ulong, source: [*]const u8, sourceLen: c_ulong) c_int;
    pub extern "c" fn uncompress(dest: [*]u8, destLen: *c_ulong, source: [*]const u8, sourceLen: c_ulong) c_int;
};

fn zlibCompress(allocator: Allocator, input: []const u8) Error![]u8 {
    const bound = c.compressBound(@intCast(input.len));
    const compressed = try allocator.alloc(u8, bound);
    errdefer allocator.free(compressed);
    var out_len: c_ulong = bound;
    const res = c.compress(compressed.ptr, &out_len, input.ptr, @intCast(input.len));
    if (res != c.Z_OK) return error.InvalidData;
    return allocator.realloc(compressed, out_len);
}

fn zlibDecompress(allocator: Allocator, input: []const u8, max_size: usize) Error![]u8 {
    const out = try allocator.alloc(u8, max_size);
    errdefer allocator.free(out);
    var out_len: c_ulong = max_size;
    const res = c.uncompress(out.ptr, &out_len, input.ptr, @intCast(input.len));
    if (res != c.Z_OK) return error.InvalidData;
    return allocator.realloc(out, out_len);
}

test "roundtrip empty" {
    const allocator = std.testing.allocator;
    const input = "";
    const compressed = try deflate(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "roundtrip hello" {
    const allocator = std.testing.allocator;
    const input = "hello world, this is a test of zflate!";
    const compressed = try deflate(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "roundtrip alice29 first 1KB" {
    const allocator = std.testing.allocator;
    const input =
        \\                ALICE'S ADVENTURES IN WONDERLAND
        \\                          Lewis Carroll
        \\               THE MILLENNIUM FULCRUM EDITION 3.0
        \\                            CHAPTER I
        \\                      Down the Rabbit-Hole
        \\
        \\  Alice was beginning to get very tired of sitting by her sister
        \\on the bank, and of having nothing to do: once or twice she had
        \\peeped into the book her sister was reading, but it had no
        \\pictures or conversations in it, `and what is the use of a book,'
        \\thought Alice `without pictures or conversation?'
        \\
        \\  So she was considering in her own mind (as well as she could,
        \\for the hot day made her feel very sleepy and stupid), whether
        \\the pleasure of making a daisy-chain would be worth the trouble
        \\of getting up and picking the daisies, when suddenly a White
        \\Rabbit with pink eyes ran close by her.
        \\
        \\  There was nothing so VERY remarkable in that; nor did Alice
        \\think it so VERY much out of the way to hear the Rabbit say to
        \\itself, `Oh dear!  Oh dear!  I shall be late!'  (when she thought
        \\it over afterwards, it occurred to her that she ought to have
        \\wondered at this, but at the time it all seemed quite natural);
        \\but when the Rabbit actually TOOK A WATCH OUT OF ITS WAISTCOAT-
        \\POCKET, and looked at it, and then hurried on, Alice started to
        \\her feet, for it flashed across her mind that she had never
        \\before seen a rabbit with either a waistcoat-pocket, or a watch to
        \\take out of it, and burning with curiosity, she ran across the
        \\field after it, and fortunately was just in time to see it pop
        \\down a large rabbit-hole under the hedge.
        \\
        \\  In another moment down went Alice after it, never once
        \\considering how in the world she was to get out again.
        \\
        \\  The rabbit-hole went straight on like a tunnel for some way,
        \\and then dipped suddenly down, so suddenly that Alice had not a
        \\moment to think about stopping herself before she found herself
        \\falling down a very deep well.
        \\
        \\  Either the well was very deep, or she fell very slowly, for she
        \\had plenty of time as she went down to look about her and to
        \\wonder what was going to happen next.  First, she tried to look
        \\down and make out what she was coming to, but it was too dark to
        \\see anything; then she looked at the sides of the well, and
        \\noticed that they were filled with cupboards and book-shelves;
        \\here and there she saw maps and pictures hung upon pegs.  She
        \\took down a jar from one of the shelves as she passed; it was
        \\labelled `ORANGE MARMALADE', but to her great disappointment it
        \\was empty: she did not like to drop the jar for fear of killing
        \\somebody, so managed to put it into one of the cupboards as she
        \\fell past it.
        \\
        \\  `Well!' thought Alice to herself, `after such a fall as this, I
        \\shall think nothing of tumbling down stairs!  How brave they'll
        \\all think me at home!  Why, I wouldn't say anything about it,
        \\even if I fell off the top of the house!' (Which was very likely
        \\true.)
        \\
        \\  Down, down, down.  Would the fall NEVER come to an end!  `I
        \\wonder how many miles I've fallen by this time?' she said aloud.
        \\`I must be getting somewhere near the centre of the earth.  Let
        \\me see: that would be four thousand miles down, I think--' (for,
        \\you see, Alice had learnt several things of this sort in her
        \\lessons in the schoolroom, and though this was not a VERY good
        \\opportunity for showing off her knowledge, as there was no one to
        \\listen to her, still it was good practice to say it over) `--yes,
        \\that's about the right distance--but then I wonder what Latitude
        \\or Longitude I've got to?'  (Alice had no idea what Latitude was,
        \\or Longitude either, but thought they were nice grand words to
        \\say.)
        \\
        \\  Presently she began again.  `I wonder if I shall fall right
        \\THROUGH the earth!  How funny it'll seem to come out among the
        \\people that walk with their heads downward!  The Antipathies, I
        \\think--' (she was rather glad there WAS no one listening, this
        \\time, as it didn't sound at all the right word) `--but I shall
        \\have to ask them what the name of the country is, you know.
        \\Please, Ma'am, is this New Zealand or Australia?'  (and she
        \\tried to curtsey as she spoke--fancy CURTSEYING as you're
        \\falling through the air!  Do you think you could manage it?)
        \\`And what an ignorant little girl she'll think me for asking!
        \\No, it'll never do to ask: perhaps I shall see it written up
        \\somewhere.'
        \\
        \\  Down, down, down.  There was nothing else to do, so Alice soon
        \\began talking again.  `Dinah'll miss me very much to-night, I
        \\should think!'  (Dinah was the cat.)  `I hope they'll remember
        \\her saucer of milk at tea-time.  Dinah my dear!  I wish you
        \\were down here with me!  There are no mice in the air, I'm
        \\afraid, but you might catch a bat, and that's very like a mouse,
        \\you know.  But do cats eat bats, I wonder?'  And here Alice
        \\began to get rather sleepy, and went on saying to herself, in a
        \\dreamy sort of way, `Do cats eat bats?  Do cats eat bats?' and
        \\sometimes, `Do bats eat cats?' for, you see, as she couldn't
        \\answer either question, it didn't much matter which way she
        \\put it.  She felt that she was dozing off, and had just begun
        \\to dream that she was walking hand in hand with Dinah, and
        \\saying to her very earnestly, `Now, Dinah, tell me the truth:
        \\did you ever eat a bat?' when suddenly, thump! thump! down
        \\she came upon a heap of sticks and dry leaves, and the fall
        \\was over.
        \\
        \\  Alice was not a bit hurt, and she jumped up on to her feet in
        \\a moment: she looked up, but it was all dark overhead; before
        \\her was another long passage, and the White Rabbit was still in
        \\sight, hurrying down it.  There was not a moment to be lost:
        \\away went Alice like the wind, and was just in time to hear it
        \\say, as it turned a corner, `Oh my ears and whiskers, how late
        \\it's getting!'  She was close behind it when she turned the
        \\corner, but the Rabbit was no longer to be seen: she found
        \\herself in a long, low hall, which was lit up by a row of lamps
        \\hanging from the roof.
        \\
        \\  There were doors all round the hall, but they were all locked;
        \\and when Alice had been all the way down one side and up the
        \\other, trying every door, she walked sadly down the middle,
        \\wondering how she was ever to get out again.
        \\
        \\  Suddenly she came upon a little three-legged table, all made of
        \\solid glass; there was nothing on it except a tiny golden key,
        \\and Alice's first thought was that it might belong to one of the
        \\doors of the hall; but, alas! either the locks were too large,
        \\or the key was too small, but at any rate it would not open any
        \\of them.  However, on the second time round, she came upon a
        \\low curtain she had not noticed before, and behind it was a
        \\little door about fifteen inches high: she tried the little
        \\golden key in the lock, and to her great delight it fitted!
    ;
    const compressed = try deflate(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "zflate deflate -> zlib inflate" {
    const allocator = std.testing.allocator;
    const input = "Cross compatibility test between zflate and zlib.";
    const compressed = try deflate(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(allocator, compressed, 4096);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "zlib deflate -> zflate inflate" {
    const allocator = std.testing.allocator;
    const input = "Cross compatibility test between zlib and zflate.";
    const compressed = try zlibCompress(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "zflate deflate -> zlib inflate empty" {
    const allocator = std.testing.allocator;
    const input = "";
    const zflate_compressed = try deflate(allocator, input);
    defer allocator.free(zflate_compressed);
    const zlib_decompressed = try zlibDecompress(allocator, zflate_compressed, 4096);
    defer allocator.free(zlib_decompressed);
    try std.testing.expectEqualStrings(input, zlib_decompressed);
}

test "zflate deflate -> zlib inflate single byte" {
    const allocator = std.testing.allocator;
    const input = "A";
    const zflate_compressed = try deflate(allocator, input);
    defer allocator.free(zflate_compressed);
    const zlib_decompressed = try zlibDecompress(allocator, zflate_compressed, 4096);
    defer allocator.free(zlib_decompressed);
    try std.testing.expectEqualStrings(input, zlib_decompressed);
}

test "raw deflate roundtrip" {
    const allocator = std.testing.allocator;
    const input = "raw deflate without zlib wrapper";
    const compressed = try deflateRaw(allocator, input);
    defer allocator.free(compressed);
    const decompressed = try inflateRaw(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "streaming compressor roundtrip" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator, .default);
    defer compressor.deinit();

    try compressor.write("Hello, ");
    try compressor.write("world!");
    try compressor.write(" This is a streaming test.");

    const compressed = try compressor.finish();
    defer allocator.free(compressed);

    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings("Hello, world! This is a streaming test.", decompressed);
}

test "compression level store" {
    const allocator = std.testing.allocator;
    const input = "Store level test";
    const compressed = try deflateWithLevel(allocator, input, .store);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "compression level fast" {
    const allocator = std.testing.allocator;
    const input = "Fast level test for quick compression";
    const compressed = try deflateWithLevel(allocator, input, .fast);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "compression level best" {
    const allocator = std.testing.allocator;
    const input = "Best level test for maximum compression ratio";
    const compressed = try deflateWithLevel(allocator, input, .best);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(input, decompressed);
}

test "multi-block roundtrip large data" {
    const allocator = std.testing.allocator;
    // Generate ~20KB of repeating data to force multiple blocks
    var data = try allocator.alloc(u8, 20000);
    defer allocator.free(data);
    for (0..20000) |i| {
        data[i] = @truncate((i * 7 + 13) % 256);
    }
    const compressed = try deflate(allocator, data);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(data, decompressed);
}

test "gzip roundtrip" {
    const allocator = std.testing.allocator;
    const input = "Hello, gzip world! This is a test of the gzip format support in zflate.";
    const compressed = try gzipCompress(allocator, input, "test.txt", .default);
    defer allocator.free(compressed);
    const result = try gzipDecompress(allocator, compressed);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);
    try std.testing.expectEqualStrings(input, result.data);
    try std.testing.expectEqualStrings("test.txt", result.filename.?);
}

test "gzip roundtrip empty" {
    const allocator = std.testing.allocator;
    const input = "";
    const compressed = try gzipCompress(allocator, input, null, .default);
    defer allocator.free(compressed);
    const result = try gzipDecompress(allocator, compressed);
    defer allocator.free(result.data);
    defer if (result.filename) |f| allocator.free(f);
    try std.testing.expectEqualStrings(input, result.data);
    try std.testing.expect(result.filename == null);
}
