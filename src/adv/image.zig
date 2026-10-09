//! Image decoding for Advanced Content (HD DVD Vol. 1 §4.3.19.10, Vol. 3 §7.8.3): PNG (including 8-bit indexed
//! with transparency, as cursor images are) and JPEG, through stb_image, into premultiplied RGBA canvases.
//! No VLC dependency.

const std = @import("std");
const stb = @import("stb");
const raster = @import("raster.zig");

pub const Error = error{ BadImage, OutOfMemory };

/// Largest side accepted (the aperture is at most 1920×1080; images may be bigger and cropped, within reason).
pub const max_side = 8192;

pub const Kind = enum { png, jpeg, mng, unknown };

pub fn kindOf(bytes: []const u8) Kind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\x8aMNG\r\n\x1a\n")) return .mng;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    return .unknown;
}

/// Decodes a PNG or JPEG into a premultiplied canvas (caller frees it).
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!raster.Canvas {
    switch (kindOf(bytes)) {
        .png, .jpeg => {},
        else => return error.BadImage,
    }
    if (bytes.len > std.math.maxInt(c_int)) return error.BadImage;
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const px = stb.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4) orelse return error.BadImage;
    defer stb.stbi_image_free(px);
    if (w <= 0 or h <= 0 or w > max_side or h > max_side) return error.BadImage;
    const c = try raster.Canvas.init(gpa, @intCast(w), @intCast(h));
    const src: [*]const [4]u8 = @ptrCast(px);
    for (c.px, src[0..c.px.len]) |*d, s| d.* = (raster.Color{ .r = s[0], .g = s[1], .b = s[2], .a = s[3] }).premultiplied();
    return c;
}

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

/// A PNG of `w`×`h` RGBA pixels (stored, uncompressed deflate), for tests.
fn testPng(gpa: std.mem.Allocator, w: u32, h: u32, px: []const [4]u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        for (px[y * w ..][0..w]) |p| try raw.appendSlice(gpa, &p);
    }
    // zlib stream with stored blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var i: usize = 0;
    while (true) {
        const n = @min(raw.items.len - i, 65535);
        const last = i + n == raw.items.len;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n))));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~@as(u16, @intCast(n)))));
        try z.appendSlice(gpa, raw.items[i..][0..n]);
        i += n;
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

test "decode a PNG, premultiplied" {
    const gpa = testing.allocator;
    const png = try testPng(gpa, 2, 1, &.{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 128 } });
    defer gpa.free(png);
    try testing.expectEqual(Kind.png, kindOf(png));
    var c = try decode(gpa, png);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), c.w);
    try testing.expectEqual(raster.Px{ 255, 0, 0, 255 }, c.at(0, 0));
    try testing.expectEqual(raster.Px{ 0, 0, 128, 128 }, c.at(1, 0));
    try testing.expectError(error.BadImage, decode(gpa, "not an image"));
    try testing.expectError(error.BadImage, decode(gpa, png[0..20]));
}
