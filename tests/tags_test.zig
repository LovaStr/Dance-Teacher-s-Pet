const std = @import("std");
const tags = @import("tags");

const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn parse(bytes: []const u8, v1: bool) tags.Tags {
    var s = tags.SliceSource{ .bytes = bytes };
    return tags.read(s.source(), v1);
}

fn syncsafeBytes(n: u32) [4]u8 {
    return .{ @intCast((n >> 21) & 0x7f), @intCast((n >> 14) & 0x7f), @intCast((n >> 7) & 0x7f), @intCast(n & 0x7f) };
}

/// An ID3v2.4 tag made of the given (id, body) frames.
fn id3v24(comptime frames: []const [2][]const u8) []const u8 {
    const result = comptime blk: {
        var body: []const u8 = "";
        for (frames) |f| {
            const sz = syncsafeBytes(f[1].len);
            body = body ++ f[0] ++ &sz ++ "\x00\x00" ++ f[1];
        }
        const sz = syncsafeBytes(body.len);
        break :blk "ID3\x04\x00\x00" ++ &sz ++ body;
    };
    return result;
}

test "ID3v2.4 UTF-8 title and artist" {
    const t = parse(id3v24(&.{ .{ "TIT2", "\x03Blue Moon" }, .{ "TPE1", "\x03Ella" } }), true);
    try expectEqualStrings("Blue Moon", t.title.get().?);
    try expectEqualStrings("Ella", t.artist.get().?);
}

test "ID3v2 UTF-16 with BOM and Latin-1" {
    const t = parse(id3v24(&.{
        .{ "TIT2", "\x01\xff\xfeH\x00\xe5\x00" },
        .{ "TPE1", "\x00Bj\xf6rk" },
    }), false);
    try expectEqualStrings("H\u{e5}", t.title.get().?);
    try expectEqualStrings("Bj\u{f6}rk", t.artist.get().?);
}

test "ID3v2.2 frames" {
    const bytes = "ID3\x02\x00\x00\x00\x00\x00\x15" ++
        "TT2\x00\x00\x06\x03Hello" ++ "TP1\x00\x00\x03\x03Me";
    const t = parse(bytes, false);
    try expectEqualStrings("Hello", t.title.get().?);
    try expectEqualStrings("Me", t.artist.get().?);
}

test "ID3v1 is used for MP3 when there is no ID3v2" {
    var b: [300]u8 = @splat(0);
    const off = b.len - 128;
    @memcpy(b[off..][0..3], "TAG");
    @memcpy(b[off + 3 ..][0..4], "Song");
    @memcpy(b[off + 33 ..][0..3], "Abe");
    const t = parse(&b, true);
    try expectEqualStrings("Song", t.title.get().?);
    try expectEqualStrings("Abe", t.artist.get().?);
    try expect(parse(&b, false).title.get() == null);
}

test "FLAC Vorbis comments, keys case-insensitive" {
    const vendor = "ref";
    const c1 = "title=Fly Me";
    const c2 = "ARTIST=Frank";
    const c3 = "ALBUM=Ignored";
    const body = "\x03\x00\x00\x00" ++ vendor ++ "\x03\x00\x00\x00" ++
        "\x0c\x00\x00\x00" ++ c1 ++ "\x0c\x00\x00\x00" ++ c2 ++ "\x0d\x00\x00\x00" ++ c3;
    const bytes = "fLaC" ++
        "\x00\x00\x00\x04\x00\x00\x00\x00" ++ // STREAMINFO stub is not parsed: 4 bytes of padding
        "\x84\x00\x00" ++ [_]u8{body.len} ++ body;
    const t = parse(bytes, false);
    try expectEqualStrings("Fly Me", t.title.get().?);
    try expectEqualStrings("Frank", t.artist.get().?);
}

test "no tags: fallback to file name; title only; both" {
    const gpa = std.testing.allocator;
    var none = tags.Tags{};
    const a = try tags.displayName(gpa, &none, "file");
    defer gpa.free(a);
    try expectEqualStrings("file", a);

    const only = parse(id3v24(&.{.{ "TIT2", "\x03Just Title" }}), false);
    const b = try tags.displayName(gpa, &only, "file");
    defer gpa.free(b);
    try expectEqualStrings("Just Title", b);

    const both = parse(id3v24(&.{ .{ "TIT2", "\x03A" }, .{ "TPE1", "\x03B" } }), false);
    const c = try tags.displayName(gpa, &both, "file");
    defer gpa.free(c);
    try expectEqualStrings("A - B", c);
}

test "garbage and truncated input do not crash" {
    _ = parse("", true);
    _ = parse("ID3\x04\x00\x00\x7f\x7f\x7f\x7f TIT2", true);
    _ = parse("fLaC\x84\xff\xff\xff", true);
}
