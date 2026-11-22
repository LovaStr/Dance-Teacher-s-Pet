//! Song title / artist from file metadata: ID3v2 (and ID3v1 for MP3) and FLAC
//! Vorbis comments. Pure Zig, no allocation while parsing, and independent of
//! how the bytes are read (see `Source`), so it is unit-testable without SDL.
//! Only the metadata is read, never the audio data.

const std = @import("std");

/// Longest title / artist kept, in UTF-8 bytes.
pub const max_field = 256;

/// A UTF-8 string in a fixed buffer.
pub const Field = struct {
    buf: [max_field]u8 = undefined,
    len: usize = 0,

    /// The trimmed text, or null when empty.
    pub fn get(self: *const Field) ?[]const u8 {
        const s = std.mem.trim(u8, self.buf[0..self.len], " \t\r\n\x00");
        return if (s.len == 0) null else s;
    }

    fn setUtf8(self: *Field, bytes: []const u8) void {
        const n = @min(bytes.len, max_field);
        // Truncation may split a multi-byte character: back off to a valid prefix.
        var k: usize = 0;
        while (k < 4 and k <= n) : (k += 1) {
            if (std.unicode.utf8ValidateSlice(bytes[0 .. n - k])) {
                @memcpy(self.buf[0 .. n - k], bytes[0 .. n - k]);
                self.len = n - k;
                return;
            }
        }
        self.setLatin1(bytes); // mislabelled: treat as Latin-1
    }

    fn setLatin1(self: *Field, bytes: []const u8) void {
        self.len = 0;
        for (bytes) |b| self.push(b);
    }

    fn setUtf16(self: *Field, bytes: []const u8, big_endian: bool) void {
        self.len = 0;
        var i: usize = 0;
        while (i + 2 <= bytes.len) {
            const unit = unit16(bytes[i..][0..2], big_endian);
            i += 2;
            if (unit == 0) break;
            if (unit >= 0xD800 and unit < 0xDC00) { // high surrogate: needs a low one
                if (i + 2 > bytes.len) break;
                const lo = unit16(bytes[i..][0..2], big_endian);
                if (lo < 0xDC00 or lo > 0xDFFF) continue; // lone surrogate: drop it
                i += 2;
                self.push(0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (lo - 0xDC00));
            } else if (unit < 0xDC00 or unit > 0xDFFF) {
                self.push(unit);
            }
        }
    }

    /// Append one code point; stops silently when full.
    fn push(self: *Field, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > max_field) return;
        @memcpy(self.buf[self.len..][0..n], tmp[0..n]);
        self.len += n;
    }
};

pub const Tags = struct {
    title: Field = .{},
    artist: Field = .{},
};

/// Random-access byte source (a file, or memory in tests).
pub const Source = struct {
    ctx: *anyopaque,
    /// Read up to `buf.len` bytes at `offset`; returns how many were read.
    readFn: *const fn (ctx: *anyopaque, offset: u64, buf: []u8) usize,
    size: u64,

    fn readExact(self: Source, offset: u64, buf: []u8) bool {
        if (offset + buf.len > self.size) return false;
        return self.readFn(self.ctx, offset, buf) == buf.len;
    }
};

/// A `Source` over a byte slice.
pub const SliceSource = struct {
    bytes: []const u8,

    pub fn source(self: *SliceSource) Source {
        return .{ .ctx = self, .readFn = readSlice, .size = self.bytes.len };
    }

    fn readSlice(ctx: *anyopaque, offset: u64, buf: []u8) usize {
        const self: *SliceSource = @ptrCast(@alignCast(ctx));
        if (offset >= self.bytes.len) return 0;
        const n = @min(buf.len, self.bytes.len - @as(usize, @intCast(offset)));
        @memcpy(buf[0..n], self.bytes[@intCast(offset)..][0..n]);
        return n;
    }
};

/// Read title and artist. FLAC is recognised by content; otherwise ID3v2 is tried,
/// then (only if `allow_id3v1`, i.e. for MP3) the ID3v1 tag at the end of the file.
pub fn read(src: Source, allow_id3v1: bool) Tags {
    var t = Tags{};
    if (readFlac(src, &t)) return t;
    _ = readId3v2(src, &t);
    if (allow_id3v1) readId3v1(src, &t);
    return t;
}

/// "title - artist", or just the title when there is no artist. Without a
/// title the result is `fallback` (the caller passes the file name). Caller owns it.
pub fn displayName(gpa: std.mem.Allocator, tags: *const Tags, fallback: []const u8) std.mem.Allocator.Error![]u8 {
    const title = tags.title.get() orelse return gpa.dupe(u8, fallback);
    if (tags.artist.get()) |artist| return std.fmt.allocPrint(gpa, "{s} - {s}", .{ title, artist });
    return gpa.dupe(u8, title);
}

// --- helpers ------------------------------------------------------------------

fn unit16(b: *const [2]u8, big_endian: bool) u16 {
    return std.mem.readInt(u16, b, if (big_endian) .big else .little);
}

fn syncsafe(b: []const u8) u32 {
    return (@as(u32, b[0] & 0x7f) << 21) | (@as(u32, b[1] & 0x7f) << 14) |
        (@as(u32, b[2] & 0x7f) << 7) | (b[3] & 0x7f);
}

fn be24(b: []const u8) u32 {
    return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
}

/// Undo ID3 unsynchronisation (FF 00 -> FF) in place; returns the new length.
fn unsync(buf: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        buf[out] = buf[i];
        out += 1;
        if (buf[i] == 0xFF and i + 1 < buf.len and buf[i + 1] == 0) i += 1;
    }
    return out;
}

// --- ID3v2 --------------------------------------------------------------------

fn readId3v2(src: Source, tags: *Tags) bool {
    var hdr: [10]u8 = undefined;
    if (!src.readExact(0, &hdr) or !std.mem.eql(u8, hdr[0..3], "ID3")) return false;
    const major = hdr[3];
    if (major < 2 or major > 4) return false;
    const tag_flags = hdr[5];
    var pos: u64 = 10;
    const end: u64 = @min(10 + @as(u64, syncsafe(hdr[6..10])), src.size);

    if (major >= 3 and tag_flags & 0x40 != 0) { // extended header: skip it
        var eh: [4]u8 = undefined;
        if (!src.readExact(pos, &eh)) return false;
        pos += if (major == 4) syncsafe(&eh) else 4 + @as(u64, std.mem.readInt(u32, &eh, .big));
    }

    const id_len: usize = if (major == 2) 3 else 4;
    const hdr_len: usize = if (major == 2) 6 else 10;
    const title_id = if (major == 2) "TT2" else "TIT2";
    const artist_id = if (major == 2) "TP1" else "TPE1";

    while (pos + hdr_len <= end) {
        var fh: [10]u8 = undefined;
        if (!src.readExact(pos, fh[0..hdr_len])) break;
        if (fh[0] == 0) break; // padding
        const size: u64 = switch (major) {
            2 => be24(fh[3..6]),
            3 => std.mem.readInt(u32, fh[4..8], .big),
            else => syncsafe(fh[4..8]),
        };
        const body = pos + hdr_len;
        if (body + size > end) break;
        pos = body + size;

        const is_title = std.mem.eql(u8, fh[0..id_len], title_id);
        const is_artist = std.mem.eql(u8, fh[0..id_len], artist_id);
        if (!is_title and !is_artist) continue;
        const field = if (is_title) &tags.title else &tags.artist;
        if (field.get() != null) continue;

        // Frame flags: skip compressed / encrypted frames, drop the optional
        // extra header bytes, and note per-frame unsynchronisation.
        var skip: u64 = 0;
        var frame_unsync = tag_flags & 0x80 != 0;
        if (major == 3) {
            if (fh[8] & 0xC0 != 0) continue;
            if (fh[8] & 0x20 != 0) skip += 1;
        } else if (major == 4) {
            if (fh[9] & 0x0C != 0) continue;
            if (fh[9] & 0x40 != 0) skip += 1;
            if (fh[9] & 0x01 != 0) skip += 4;
            if (fh[9] & 0x02 != 0) frame_unsync = true;
        }
        if (size <= skip) continue;

        var raw: [1024]u8 = undefined;
        var n: usize = @intCast(@min(size - skip, raw.len));
        if (!src.readExact(body + skip, raw[0..n])) continue;
        if (frame_unsync) n = unsync(raw[0..n]);
        if (n == 0) continue;
        decodeText(field, raw[0], raw[1..n]);
    }
    return true;
}

/// Decode an ID3 text frame body (after the encoding byte); the first of several
/// NUL-separated values wins.
fn decodeText(field: *Field, encoding: u8, data: []const u8) void {
    switch (encoding) {
        0 => field.setLatin1(data[0 .. std.mem.indexOfScalar(u8, data, 0) orelse data.len]),
        3 => field.setUtf8(data[0 .. std.mem.indexOfScalar(u8, data, 0) orelse data.len]),
        1, 2 => {
            var d = data;
            var big = encoding == 2;
            if (encoding == 1 and d.len >= 2) {
                if (d[0] == 0xFE and d[1] == 0xFF) {
                    big = true;
                    d = d[2..];
                } else if (d[0] == 0xFF and d[1] == 0xFE) {
                    d = d[2..];
                }
            }
            field.setUtf16(d, big);
        },
        else => {},
    }
}

// --- ID3v1 --------------------------------------------------------------------

fn readId3v1(src: Source, tags: *Tags) void {
    if (src.size < 128) return;
    var b: [128]u8 = undefined;
    if (!src.readExact(src.size - 128, &b) or !std.mem.eql(u8, b[0..3], "TAG")) return;
    if (tags.title.get() == null) tags.title.setLatin1(cutNul(b[3..33]));
    if (tags.artist.get() == null) tags.artist.setLatin1(cutNul(b[33..63]));
}

fn cutNul(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

// --- FLAC Vorbis comments -----------------------------------------------------

fn readFlac(src: Source, tags: *Tags) bool {
    var magic: [4]u8 = undefined;
    if (!src.readExact(0, &magic) or !std.mem.eql(u8, &magic, "fLaC")) return false;
    var pos: u64 = 4;
    var blocks: u32 = 0;
    while (blocks < 256) : (blocks += 1) {
        var bh: [4]u8 = undefined;
        if (!src.readExact(pos, &bh)) break;
        const len = be24(bh[1..4]);
        const body = pos + 4;
        if (bh[0] & 0x7f == 4) { // VORBIS_COMMENT
            readVorbisComments(src, body, len, tags);
            break;
        }
        if (bh[0] & 0x80 != 0) break; // last metadata block
        pos = body + len;
    }
    return true;
}

fn readVorbisComments(src: Source, start: u64, len: u64, tags: *Tags) void {
    const end = start + len;
    var pos = start;
    var w: [4]u8 = undefined;

    if (pos + 4 > end or !src.readExact(pos, &w)) return;
    pos += 4 + @as(u64, std.mem.readInt(u32, &w, .little)); // vendor string
    if (pos + 4 > end or !src.readExact(pos, &w)) return;
    const count = std.mem.readInt(u32, &w, .little);
    pos += 4;

    var i: u32 = 0;
    while (i < @min(count, 4096)) : (i += 1) {
        if (pos + 4 > end or !src.readExact(pos, &w)) return;
        const clen: u64 = std.mem.readInt(u32, &w, .little);
        pos += 4;
        if (pos + clen > end) return;
        var buf: [512]u8 = undefined;
        const n: usize = @intCast(@min(clen, buf.len));
        if (src.readExact(pos, buf[0..n])) {
            if (std.mem.indexOfScalar(u8, buf[0..n], '=')) |eq| {
                const key = buf[0..eq];
                const val = buf[eq + 1 .. n];
                if (std.ascii.eqlIgnoreCase(key, "TITLE") and tags.title.get() == null) tags.title.setUtf8(val);
                if (std.ascii.eqlIgnoreCase(key, "ARTIST") and tags.artist.get() == null) tags.artist.setUtf8(val);
            }
        }
        pos += clen;
    }
}
