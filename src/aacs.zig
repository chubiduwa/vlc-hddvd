//! AACS decryption of an HD DVD started from a volume unique key (VUK) looked up by disc ID in a KEYDB.cfg
//! database (libaacs syntax). The device-key / MKB half of AACS is skipped entirely: with a VUK the rest is
//! (AACS Pre-recorded Video Book §3.3–3.5; HD DVD book §4.3.2):
//!
//!     Kt = AES-128D(VUK, Kte)             per used slot of the disc's title key file (VTKF*.AACS)
//!     Kc = AES-G(Kt, Dtk || CPI[4..16])   per pack (Dtk = pack bytes 84..88, CPI from the EVOBU's NV_PCK)
//!     C  = AES-128CBCD(Kc, Ce, IV)        pack bytes 128..2048; AACS-wrapped files are one CBC chain under Kt
//!
//! with AES-G(x1, x2) = AES-128D(x1, x2) XOR x2 and a fixed AACS IV for every CBC operation. Pure logic,
//! no VLC dependency; the disc probe, the per-cell pack streaming and the file/ACA reads that call this are
//! integrated below the file layer, so the rest of the player always sees plain files.
//!
//! Segment/sequence keys (KEY_VF 01) and audio-only title keys (ATKF) are not used by any known disc; the
//! key use is detected but the decryption of both is [todo].

const std = @import("std");

const Aes = std.crypto.core.aes.Aes128;
const cmac = std.crypto.auth.cmac;
const testing = std.testing;

/// Administrative 2048-byte pack of an EVOB, and where its encryption starts.
pub const pack_len = 2048;
pub const clear_len = 128;

/// The IV of every CBC operation of AACS.
pub const iv = [16]u8{ 0x0B, 0xA0, 0xF8, 0xDD, 0xFE, 0xA6, 0x1F, 0xB3, 0xD8, 0xDF, 0x9F, 0x56, 0x6A, 0x05, 0x0F, 0x78 };

/// The content protection information which every EVOBU carries in its first pack (it sits in the NV_PCK's
/// GCI packet; HD DVD Vol. 2 Table 5.2.5.1-1). Byte 0's top two bits are KEY_VF, bytes 1..3 are
/// TITLE_KEY_PTR, and bits 31..30 are the CCI.
pub const Cpi = [16]u8;

/// One block decrypted under a key (AES-128 ECB, decryption direction).
pub fn aesD(key: [16]u8, d: [16]u8) [16]u8 {
    const ctx = Aes.initDec(key);
    var out: [16]u8 = undefined;
    ctx.decrypt(&out, &d);
    return out;
}

/// AES-G(x1, x2) = AES-128D(x1, x2) XOR x2 (AACS Common Cryptographic Elements book), the key-conversion
/// step AACS uses for every key below the volume unique key.
pub fn aesG(key: [16]u8, d: [16]u8) [16]u8 {
    var o = aesD(key, d);
    for (&o, d) |*x, y| x.* ^= y;
    return o;
}

/// CBC-decrypts whole 16-byte blocks in place, chaining from `iv`. A trailing partial block is left alone.
fn cbcDecrypt(key: [16]u8, data: []u8) void {
    const ctx = Aes.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        const ct = data[i..][0..16].*;
        var pt: [16]u8 = undefined;
        ctx.decrypt(&pt, &ct);
        for (&pt, prev) |*x, y| x.* ^= y;
        data[i..][0..16].* = pt;
        prev = ct;
    }
}

/// CBC-encrypts whole 16-byte blocks in place, chaining from `iv` (the test counterpart of `cbcDecrypt`).
fn cbcEncrypt(key: [16]u8, data: []u8) void {
    const ctx = Aes.initEnc(key);
    var prev: [16]u8 = iv;
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        for (&prev, data[i..][0..16]) |*x, y| x.* ^= y;
        var ct: [16]u8 = undefined;
        ctx.encrypt(&ct, &prev);
        data[i..][0..16].* = ct;
        prev = ct;
    }
}

// ---- KEYDB.cfg (libaacs syntax) ----------------------------------------------------------------------------

/// KEYDB.cfg: one line per disc,
///
///     <DISC_ID: 40 hex> = <title> [| D | <date>] | V | <VUK: 32 hex>
///
/// where DISC_ID is the SHA-1 of the disc's title key file (see `discId`). Only V (volume unique key)
/// entries are collected; other fragment types (M/Km, I/VID, D, T…) and lines that do not parse are
/// skipped, so a keydb written for other content formats can sit alongside the HD DVD ones. Comment
/// lines start with `#`.
pub const Db = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct { id: [20]u8, vuk: [16]u8 };

    pub fn deinit(db: Db, gpa: std.mem.Allocator) void {
        if (db.entries.len > 0) gpa.free(@constCast(db.entries));
    }

    /// The VUK keyed by disc ID. A pressed disc often carries several title key files (one per Advanced
    /// Content playlist group, e.g. VTKF000 + VTKF090, or a Standard plus an Advanced Content pair), and
    /// the database then has several IDs for the same disc; the first match wins.
    pub fn lookup(db: Db, id: [20]u8) ?[16]u8 {
        for (db.entries) |e| if (std.mem.eql(u8, &e.id, &id)) return e.vuk;
        return null;
    }
};

/// The disc ID: SHA-1 of the whole title key file (`VTKF.AACS`, `VTKF000.AACS`, … as read from the disc).
pub fn discId(tkf_file: []const u8) [20]u8 {
    var id: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(tkf_file, &id, .{});
    return id;
}

pub fn hexKey(s: []const u8) ?[16]u8 {
    if (s.len != 32) return null;
    var k: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, s) catch return null;
    return k;
}

pub fn hexId(s: []const u8) ?[20]u8 {
    if (s.len != 40) return null;
    var id: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, s) catch return null;
    return id;
}

pub const DbError = error{OutOfMemory};

/// Parses KEYDB.cfg text.
pub fn parseDb(gpa: std.mem.Allocator, text: []const u8) DbError!Db {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (parseDbLine(line) != null) {
            n += 1;
        }
    }

    const entries = try gpa.alloc(Db.Entry, n);
    var at: usize = 0;
    lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (parseDbLine(line)) |e| {
            entries[at] = e;
            at += 1;
        }
    }
    return .{ .entries = entries };
}

fn parseDbLine(line_in: []const u8) ?Db.Entry {
    const line = std.mem.trim(u8, line_in, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const id = hexId(std.mem.trim(u8, line[0..eq], " \t")) orelse return null;

    // Fragments come in type/value pairs after the title ("V"/VUK, "D"/date, "T"/title key, …).
    var tok = std.mem.splitScalar(u8, line[eq + 1 ..], '|');
    _ = tok.next() orelse return null; // the title
    while (true) {
        const ty = std.mem.trim(u8, tok.next() orelse return null, " \t");
        const v = std.mem.trim(u8, tok.next() orelse return null, " \t");
        if (std.mem.eql(u8, ty, "V")) {
            if (hexKey(v)) |vuk| return .{ .id = id, .vuk = vuk };
        }
    }
}

// ---- Title key file (VTKF*.AACS) ---------------------------------------------------------------------------

pub const tkf_len = 2480;
pub const tkf_slots = 64;

pub const TkfError = error{ NotTkf, BadMac };

/// The disc's title keys, by 1-based slot (the value TITLE_KEY_PTR in the CPI and in the AACS file
/// wrapper refer to).
pub const Tkf = struct {
    slots: [tkf_slots + 1]?[16]u8 = @splat(null), // [0] is unused
    used: u16 = 0,

    pub fn kt(tkf: *const Tkf, slot: u16) ?[16]u8 {
        if (slot == 0 or slot > tkf_slots) return null;
        return tkf.slots[slot];
    }
};

/// Video title key file (fixed 2480 bytes, HD DVD book Table 3-8):
///
///     0x000  12  magic "DVD_HD_V_TKF"
///     0x00C   4  BE32 file size (2480)
///     0x010  12  associated playlist name
///     0x01C 100  reserved
///     0x080  64 × 36-byte entries (+0: bit 7 set = the slot holds a key; +4: encrypted title key Kte)
///     0x9A0  16  TKF MAC = AES-128-CMAC(Kvu, bytes 0..0x9A0) — it checks the VUK before any pack is touched
///
/// `error.NotTkf` when the file is not a video title key file, `error.BadMac` when the VUK is wrong (an
/// audio title key file ATKF and the segment/sequence key variants: [todo]).
pub fn parseTkf(tkf: *const [tkf_len]u8, vuk: [16]u8) TkfError!Tkf {
    if (!std.mem.eql(u8, tkf[0..12], "DVD_HD_V_TKF")) return error.NotTkf;

    var want: [16]u8 = undefined;
    cmac.CmacAes128.create(&want, tkf[0..0x9A0], &vuk);
    if (!std.mem.eql(u8, &want, tkf[0x9A0..][0..16])) return error.BadMac;

    var t: Tkf = .{};
    for (0..tkf_slots) |i| {
        const e = tkf[0x80 + i * 36 ..][0..36];
        if (e[0] & 0x80 == 0) continue;
        t.slots[i + 1] = aesD(vuk, e[4..20].*);
        t.used += 1;
    }
    return t;
}

// ---- Packs of an EVOB --------------------------------------------------------------------------------------

/// What the EVOBU's CPI says about the packs that follow it.
pub const KeyUse = union(enum) {
    /// KEY_VF 00: the EVOBU and its packs are not encrypted.
    none,
    /// KEY_VF 01: sequence/segment key variants (not used by any known disc; [todo]).
    segment,
    /// KEY_VF 10: the 1-based VTKF slot.
    title: u16,
};

/// The key use of a pack's controlling CPI.
pub fn cpiKey(cpi: Cpi) KeyUse {
    return switch (cpi[0] >> 6) {
        0 => .none,
        2 => .{ .title = std.mem.readInt(u16, cpi[1..3], .big) },
        else => .segment,
    };
}

/// Start of the first inner packet of a pack (past its pack header), or null when it is not a pack.
fn firstPacket(p: []const u8) ?usize {
    if (!std.mem.eql(u8, p[0..4], &.{ 0, 0, 1, 0xBA }) or p[4] & 0xC0 != 0x40) return null;
    return 14 + @as(usize, p[13] & 7);
}

fn hasPesFlags(sid: u8) bool {
    return sid >= 0xBD and sid != 0xBE and sid != 0xBF;
}

/// The kinds of 2 KiB pack an EVOB multiplexes: navigation packs (never encrypted; they carry the CPI in
/// their GCI packet), highlighted-button packs (encrypted with the pack's key whenever the CPI asks for a
/// key), PES packs (the first inner header's scrambling control says encrypted or not), and everything
/// else in the clear.
pub const Kind = union(enum) {
    /// A navigation pack (NV_PCK); the CPI of the EVOBU it starts (null when there is no GCI packet).
    nav: ?Cpi,
    /// A PES pack with PES_scrambling_control set.
    scrambled,
    /// A highlighted-button pack (HL_PCK).
    highlight,
    /// Nothing to decrypt (a clear PES pack, or no inner packet at all — padding and such).
    clear,
};

/// Classifies one 2 KiB pack.
pub fn classifyPack(p: []const u8) Kind {
    const o = firstPacket(p) orelse return .clear;
    if (o + 7 > p.len or !std.mem.eql(u8, p[o .. o + 3], &.{ 0, 0, 1 })) return .clear;
    const sid = p[o + 3];
    if (sid == 0xBB) return .{ .nav = navCpi(p, o) };
    if (sid == 0xBF and p[o + 6] == 0x08) return .highlight;
    if (hasPesFlags(sid) and p[o + 6] & 0xC0 == 0x80) return if (p[o + 6] & 0x30 == 0) .clear else .scrambled;
    return .clear;
}

/// The CPI in a navigation pack's GCI packet (private_stream_2, sub_stream_id 0x04; it sits 12 bytes into
/// the GCI data). Bytes 0..128 of that pack are in the clear, so the CPI can be read while the packs it
/// applies to are still scrambled.
fn navCpi(p: []const u8, start: usize) ?Cpi {
    var q = start;
    while (q + 7 <= p.len and std.mem.eql(u8, p[q .. q + 3], &.{ 0, 0, 1 })) {
        const len: usize = std.mem.readInt(u16, p[q + 4 ..][0..2], .big);
        if (p[q + 3] == 0xBF and p[q + 6] == 0x04) {
            if (len < 1 + 12 + 16) return null;
            const at = q + 7 + 12;
            if (at + 16 > p.len) return null;
            return p[at..][0..16].*;
        }
        q += 6 + len;
    }
    return null;
}

pub const NoKey = error{NoKey};

/// Decrypts one pack in place with the title key of the slot its EVOBU's CPI names: bytes 128..2048 are
/// one CBC chain under
///
///     Kc = AES-G(Kt, pack[84..88] || CPI[4..16])
///
/// and the AACS IV (the 128 header bytes stay in the clear; (2048-128) % 16 == 0 so no partial block),
/// then the first inner header's PES_scrambling_control is cleared. `error.NoKey` when the key use is not
/// a VTKF title key or the disc's VTKF does not hold that slot (a segment key or an unreadable title key
/// file: [todo]).
pub fn decryptPack(p: *[pack_len]u8, kt: [16]u8, cpi: Cpi) void {
    var d: [16]u8 = undefined;
    @memcpy(d[0..4], p[84..88]);
    @memcpy(d[4..], cpi[4..]);
    const kc = aesG(kt, d);
    cbcDecrypt(kc, p[clear_len..pack_len]);
    if (firstPacket(p)) |o| if (hasPesFlags(p[o + 3]) and p[o + 6] & 0xC0 == 0x80) {
        p[o + 6] &= ~@as(u8, 0x30);
    };
}

pub fn decryptPackSlot(p: *[pack_len]u8, tkf: *const Tkf, cpi: Cpi) NoKey!void {
    const slot = switch (cpiKey(cpi)) {
        .title => |x| x,
        else => return error.NoKey,
    };
    const kt = tkf.kt(slot) orelse return error.NoKey;
    decryptPack(p, kt, cpi);
}

/// Structural proof that a decrypted pack is now plaintext (libfreemkv's payload_check): MPEG packet
/// start codes and length fields agree past the clear header, and AC-3 sync words land where the
/// first-access-unit pointers of Dolby Digital sub-streams say. null when there is no packet chain to
/// test (e.g. a pack whose packets all sit inside the clear header).
pub fn payloadCheck(p: []const u8) ?bool {
    var q = firstPacket(p) orelse return null;
    var tested = false;
    while (q + 6 <= pack_len) {
        if (!std.mem.eql(u8, p[q .. q + 3], &.{ 0, 0, 1 })) {
            if (q >= clear_len) return false;
            return if (tested) true else null;
        }
        if (q >= clear_len) tested = true;
        const len: usize = std.mem.readInt(u16, p[q + 4 ..][0..2], .big);
        if (p[q + 3] == 0xBD and p[q + 6] & 0xC0 == 0x80) {
            const hd = q + 9 + @as(usize, p[q + 8]);
            if (hd + 4 <= p.len) {
                const sub = p[hd];
                if ((sub >= 0x80 and sub <= 0x87) or (sub >= 0xC0 and sub <= 0xC7)) {
                    const ptr: usize = std.mem.readInt(u16, p[hd + 2 ..][0..2], .big);
                    const at = hd + 3 + ptr;
                    const end = @min(q + 6 + len, p.len);
                    if (ptr != 0 and at >= clear_len and at + 2 <= end) {
                        if (p[at] != 0x0B or p[at + 1] != 0x77) return false;
                        tested = true;
                    }
                }
            }
        }
        q += 6 + len;
    }
    return if (tested) true else null;
}

// ---- AACS-wrapped files and archive entries ----------------------------------------------------------------

/// The 283-byte AACS file wrapper around Advanced Content files, playlists and every entry of an .aca
/// archive (the same 283 + data layout around which `adv/aca.zig` reassembles archives).
pub const wrapped_header = 283;

pub const WrappedError = error{NotWrapped};

const wrapped_name_len = 272;

fn wrappedNameEndsAacs(name: []const u8) bool {
    const plain = std.mem.sliceTo(name, 0);
    if (plain.len <= 5 or !std.mem.endsWith(u8, plain, ".AACS")) return false;
    for (plain) |ch| if (ch < 0x20 or ch >= 0x7f) return false;
    return true;
}

/// Decrypts one AACS-wrapped file or archive entry in place (its 283-byte header and its data). An
/// encrypted entry is one CBC chain from byte 11 through the entry's last full 16-block under the
/// entry's title key itself (slot from the header, no AES-G step) and the AACS IV; the trailing
/// partial block is in the clear, and the name field is part of the chain. The name is decrypted from a
/// copy first: when it does not become "<name>.AACS" the bytes are not an encrypted wrapped entry (an
/// already-clear one, or unrelated data that merely starts with "AACS") and the buffer is left
/// untouched. After this, the entry is clear and the name ends in ".AACS" (what `adv/aca.zig`'s
/// `isEncrypted` looks for).
///
/// Note that `error.NotWrapped` on a copy the caller keeps is harmless: a caller which merely *looks*
/// (rather than decrypts) should drive it with `adv/aca.zig`'s checks instead.
pub fn decryptWrapped(buf: []u8, tkf: *const Tkf) WrappedError!void {
    if (buf.len < wrapped_header or !std.mem.eql(u8, buf[0..4], "AACS")) return error.NotWrapped;
    const slot = std.mem.readInt(u16, buf[5..7], .big);
    const kt = tkf.kt(slot) orelse return error.NotWrapped;

    // The name field is part of the chain: what it decrypts to tells encrypted wrapped entries apart.
    var name: [wrapped_name_len]u8 = buf[11..wrapped_header].*;
    cbcDecrypt(kt, &name);
    if (!wrappedNameEndsAacs(std.mem.sliceTo(name[0..], 0))) return error.NotWrapped;

    cbcDecrypt(kt, buf[11..][0..(buf.len - 11) / 16 * 16]);
}

// ---- tests (synthetic data only) ---------------------------------------------------------------------------

test "AES-128 ECB (FIPS-197) and AES-G" {
    const key: [16]u8 = .{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
    const in: [16]u8 = .{ 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a };
    const out: [16]u8 = .{ 0x3a, 0xd7, 0x7b, 0xb4, 0x0d, 0x7a, 0x36, 0x60, 0xa8, 0x9e, 0xca, 0xf3, 0x24, 0x66, 0xef, 0x97 };

    var e: [16]u8 = undefined;
    Aes.initEnc(key).encrypt(&e, &in);
    try testing.expectEqualSlices(u8, &out, &e);
    try testing.expectEqualSlices(u8, &in, &aesD(key, out));

    const g = aesG(key, in);
    const d = aesD(key, in);
    for (g, d, in) |x, y, z| try testing.expectEqual(x, y ^ z);
}

test "CBC round trip" {
    const key: [16]u8 = @splat(0x3a);
    // 50 bytes of "plaintext": 48 inside the chain, 2 past the last full block (left alone both ways).
    var plain: [50]u8 = undefined;
    for (&plain, 0..) |*x, i| x.* = @truncate(i * 7 + 3);

    var ct = plain;
    cbcEncrypt(key, &ct);
    try testing.expect(!std.mem.eql(u8, &plain, &ct));

    cbcDecrypt(key, &ct);
    try testing.expectEqualSlices(u8, &plain, &ct);
}

test "KEYDB.cfg" {
    // All disc IDs and VUKs here are synthetic; the titles (plain, with a "(Disc 1)" release qualifier,
    // with accented characters) exist to show lines of any title shape parse the same way.
    const text =
        \\# a key database
        \\
        \\DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF = Movie 1    | V | 31415926535897932384626433832795
        \\0123456789ABCDEF0123456789ABCDEF01234567 = Movie 2 (Disc 1)| D | 2007-04-11 | V | 27182818284590452353602874713527
        \\0123456789abcdef0123456789abcdef01234567 = Movie 2 (Disc 1, lowercase id) | D | 2007-04-11 | V | 27182818284590452353602874713527
        \\FEDCBA9876543210FEDCBA9876543210FEDCBA98 = Movie 3 en été (à Paris) | V | 11112222333344445555666677778888
        \\CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC = Movie 4: no vuk yet    | D | 2007-04-11
        \\D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5 | not an entry
        \\D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5D5 = Movie 5: bad hex | V | 123456781234567812345678123456GG
    ;
    var db = try parseDb(testing.allocator, text);
    defer db.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), db.entries.len);

    try testing.expectEqualSlices(
        u8,
        &hexKey("31415926535897932384626433832795").?,
        &db.lookup(hexId("DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF").?).?,
    );
    try testing.expectEqualSlices(
        u8,
        &hexKey("27182818284590452353602874713527").?,
        &db.lookup(hexId("0123456789ABCDEF0123456789ABCDEF01234567").?).?,
    );
    try testing.expectEqualSlices(
        u8,
        &hexKey("11112222333344445555666677778888").?,
        &db.lookup(hexId("FEDCBA9876543210FEDCBA9876543210FEDCBA98").?).?,
    );
    try testing.expect(db.lookup(@splat(0)) == null);
}

/// A synthetic video title key file: the given 1-based slots hold title keys `kts[s]` under `vuk`, and
/// the TKF MAC of the rest is made to match.
fn fakeTkf(vuk: [16]u8, comptime slots: []const u16, kts: []const [16]u8) [tkf_len]u8 {
    var t: [tkf_len]u8 = @splat(0);
    @memcpy(t[0..12], "DVD_HD_V_TKF");
    std.mem.writeInt(u32, t[0xC..][0..4], tkf_len, .big);
    @memcpy(t[0x10..][0..12], "VPLST000.XPL");
    for (slots, kts) |slot, kt| {
        const e = t[0x80 + (slot - 1) * 36 ..][0..36];
        e[0] = 0x80; // BIFO: the slot holds a key
        var kte: [16]u8 = undefined;
        Aes.initEnc(vuk).encrypt(&kte, &kt);
        @memcpy(e[4..20], &kte);
        @memset(e[20..36], 0xFF); // binding MAC is all-FF on pre-recorded discs
    }
    var want: [16]u8 = undefined;
    cmac.CmacAes128.create(&want, t[0..0x9A0], &vuk);
    @memcpy(t[0x9A0..][0..16], &want);
    return t;
}

test "TKF parse and MAC" {
    const vuk: [16]u8 = @splat(0x5a);
    const kt1: [16]u8 = @splat(0x11);
    const kt2: [16]u8 = @splat(0x22);
    const t = fakeTkf(vuk, &.{ 1, 5 }, &.{ kt1, kt2 });

    const tkf = try parseTkf(&t, vuk);
    try testing.expectEqual(@as(u16, 2), tkf.used);
    try testing.expectEqualSlices(u8, &kt1, &tkf.kt(1).?);
    try testing.expectEqualSlices(u8, &kt2, &tkf.kt(5).?);
    try testing.expect(tkf.kt(2) == null and tkf.kt(0) == null and tkf.kt(65) == null);

    // the disc ID is the SHA-1 of the file
    var id: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&t, &id, .{});
    try testing.expectEqualSlices(u8, &id, &discId(&t));

    try testing.expectError(error.BadMac, parseTkf(&t, @splat(0x5b)));
    var not_tkf = t;
    not_tkf[0] = 'X';
    try testing.expectError(error.NotTkf, parseTkf(&not_tkf, vuk));
}

test "CPI key use" {
    const cpi: Cpi = @splat(0);
    try testing.expectEqual(KeyUse.none, cpiKey(cpi));

    var seg: Cpi = @splat(0);
    seg[0] = 0x40; // KEY_VF 01
    try testing.expectEqual(KeyUse.segment, cpiKey(seg));

    var tit: Cpi = @splat(0);
    tit[0] = 0x80; // KEY_VF 10
    std.mem.writeInt(u16, tit[1..3], 17, .big); // TITLE_KEY_PTR = 17
    try testing.expectEqual(KeyUse{ .title = 17 }, cpiKey(tit));
}

/// An encrypted pack and its plaintext: a PES pack whose payload holds one Dolby Digital sub-stream
/// (the AC-3 sync word where the sub-stream's first AU pointer says, so that `payloadCheck` can prove
/// the decryption), with PES_scrambling_control set in the encrypted copy. The pack covers the whole
/// AACS layout: bytes 0..128 clear (pack header, video PES header), bytes 128..2048 one CBC chain under
/// Kc = AES-G(kt, pack[84..88] || cpi[4..16]).
fn fakeScrambledPack(kt: [16]u8, cpi: Cpi, plain: *[pack_len]u8, scrambled: *[pack_len]u8) void {
    @memset(plain, 0);
    std.mem.writeInt(u32, plain[0..4], 0x000001BA, .big);
    plain[4] = 0x44; // '01' of the pack header
    plain[13] = 0x00; // no stuffing: first inner packet at 14
    // the video PES the pack's chain starts with (its header is in the clear part)
    std.mem.writeInt(u32, plain[14..][0..4], 0x000001E0, .big);
    std.mem.writeInt(u16, plain[18..][0..2], 108, .big);
    plain[20] = 0x80; // PES flags '10', not scrambled
    // past the clear header: a private-stream packet carrying a Dolby Digital sub-stream
    const s2 = 128;
    std.mem.writeInt(u32, plain[s2..][0..4], 0x000001BD, .big);
    std.mem.writeInt(u16, plain[s2 + 4 ..][0..2], @intCast(pack_len - s2 - 6), .big);
    plain[s2 + 6] = 0x80;
    plain[s2 + 7] = 0x80;
    plain[s2 + 8] = 0x00;
    const hd = s2 + 9;
    plain[hd] = 0x80; // sub-stream id: Dolby Digital
    plain[hd + 2] = 0x00;
    plain[hd + 3] = 0x00;
    plain[hd + 4] = 16; // first access unit pointer (BE16, bytes 2..4)
    plain[hd + 3 + 16] = 0x0B;
    plain[hd + 3 + 17] = 0x77;

    scrambled.* = plain.*;
    scrambled[20] |= 0x30; // PES_scrambling_control 11
    var d: [16]u8 = undefined;
    @memcpy(d[0..4], plain[84..88]);
    @memcpy(d[4..], cpi[4..]);
    const kc = aesG(kt, d);
    cbcEncrypt(kc, scrambled[clear_len..pack_len]);
}

test "pack decrypt" {
    const vuk: [16]u8 = @splat(0x5a);
    const kt1: [16]u8 = @splat(0x11);
    var cpi: Cpi = undefined;
    cpi[0] = 0x80; // KEY_VF 10
    std.mem.writeInt(u16, cpi[1..3], 1, .big); // TITLE_KEY_PTR = 1
    for (cpi[4..], 0..) |*x, i| x.* = @truncate(i * 3 + 1);

    var plain: [pack_len]u8 = undefined;
    var scrambled: [pack_len]u8 = undefined;
    fakeScrambledPack(kt1, cpi, &plain, &scrambled);

    // the pack is classified
    try testing.expectEqual(Kind.scrambled, classifyPack(&scrambled));
    try testing.expectEqual(Kind.clear, classifyPack(&plain));

    // the pack with no key slot does not decrypt (and stays scrambled)
    const none_tkf: Tkf = .{};
    var p = scrambled;
    try testing.expectError(error.NoKey, decryptPackSlot(&p, &none_tkf, cpi));
    try testing.expectEqualSlices(u8, &scrambled, &p);

    // the disc's key decrypts it into the packet chain the payload check proves
    const tkf = try parseTkf(&fakeTkf(vuk, &.{1}, &.{kt1}), vuk);
    try decryptPackSlot(&p, &tkf, cpi);
    try testing.expectEqualSlices(u8, &plain, &p);
    try testing.expectEqual(@as(?bool, true), payloadCheck(&p));

    // a wrong title key leaves ciphertext that fails the structural check (the first start code past
    // the clear header is garbage)
    {
        var q = scrambled;
        const tkf_wrong = try parseTkf(&fakeTkf(vuk, &.{1}, &.{@as([16]u8, @splat(0x99))}), vuk);
        try decryptPackSlot(&q, &tkf_wrong, cpi);
        try testing.expectEqual(@as(?bool, false), payloadCheck(&q));
    }

    // a pack whose slot is empty does not decrypt
    {
        var q = scrambled;
        var cpi2 = cpi;
        std.mem.writeInt(u16, cpi2[1..3], 2, .big);
        try testing.expectError(error.NoKey, decryptPackSlot(&q, &tkf, cpi2));
    }
}

test "pack kinds" {
    // a navigation pack: system header stand-in, then the GCI packet (private_stream_2, sub_stream_id
    // 0x04) with the CPI at offset 12 of the GCI data
    var p: [pack_len]u8 = @splat(0);
    std.mem.writeInt(u32, p[0..4], 0x000001BA, .big);
    p[4] = 0x44;
    std.mem.writeInt(u32, p[14..][0..4], 0x000001BB, .big);
    std.mem.writeInt(u16, p[18..][0..2], 40, .big);
    const q = 14 + 6 + 40;
    std.mem.writeInt(u32, p[q..][0..4], 0x000001BF, .big);
    std.mem.writeInt(u16, p[q + 4 ..][0..2], 30, .big); // sub_stream_id + 28 bytes of GCI data (CPI last)
    p[q + 6] = 0x04;
    var cpi: Cpi = @splat(0xAA);
    cpi[0] = 0x80;
    p[q + 7 + 12 ..][0..16].* = cpi;
    const kind = classifyPack(&p);
    try testing.expect(kind.nav != null);
    try testing.expectEqualSlices(u8, &cpi, &kind.nav.?);

    // a highlighted-button pack: private_stream_2, sub_stream_id 0x08
    var h: [pack_len]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], 0x000001BA, .big);
    h[4] = 0x44;
    std.mem.writeInt(u32, h[14..][0..4], 0x000001BF, .big);
    h[20] = 0x08;
    try testing.expectEqual(Kind.highlight, classifyPack(&h));

    // not a pack at all (padding): nothing to see
    var pad: [pack_len]u8 = @splat(0xAA);
    try testing.expectEqual(Kind.clear, classifyPack(&pad));
}

test "AACS-wrapped entry" {
    const vuk: [16]u8 = @splat(0x5a);
    const kt1: [16]u8 = @splat(0x11);
    const kt2: [16]u8 = @splat(0x22);
    const tkf = try parseTkf(&fakeTkf(vuk, &.{ 1, 2 }, &.{ kt1, kt2 }), vuk);

    // 380 bytes of data after a 283-byte header: the chain covers full 16-blocks of header's name field
    // plus data, and the trailing partial block (652 % 16 = 12 bytes) is in the clear
    const data_len = 380;
    var entry: [wrapped_header + data_len]u8 = @splat(0);
    @memcpy(entry[0..4], "AACS");
    entry[4] = 1; // an encrypted entry on a pressed disc
    std.mem.writeInt(u16, entry[5..7], 2, .big); // title key slot 2
    std.mem.writeInt(u24, entry[8..11], data_len, .big);
    const name = "extras menus.aca.AACS";
    @memcpy(entry[11..][0..name.len], name);
    for (entry[wrapped_header..], 0..) |*x, i| x.* = @truncate(i * 5 + 9);

    // the encrypted entry
    var enc = entry;
    cbcEncrypt(kt2, enc[11..][0..(enc.len - 11) / 16 * 16]);
    try testing.expect(!std.mem.endsWith(u8, std.mem.sliceTo(enc[11..wrapped_header], 0), ".AACS"));

    // decrypted in place back to exactly the plaintext
    var st = enc;
    try decryptWrapped(&st, &tkf);
    try testing.expectEqualSlices(u8, &entry, &st);

    // an already-clear wrapped entry is untouched: its name is plaintext and decrypting it with a key
    // would not give ".AACS" again
    var clear = entry;
    try testing.expectError(error.NotWrapped, decryptWrapped(&clear, &tkf));
    try testing.expectEqualSlices(u8, &entry, &clear);

    // the wrong key does not touch the entry either
    const tkf_wrong = try parseTkf(&fakeTkf(vuk, &.{ 1, 2 }, &.{ kt1, kt1 }), vuk);
    var wrong = enc;
    try testing.expectError(error.NotWrapped, decryptWrapped(&wrong, &tkf_wrong));
    try testing.expectEqualSlices(u8, &enc, &wrong);

    // data with an "AACS" header but no ".AACS" name is not an entry
    var plain_file = entry;
    @memcpy(plain_file[11..][0..5], "ZZZZZ");
    try testing.expectError(error.NotWrapped, decryptWrapped(&plain_file, &tkf));
    try testing.expectEqual(@as(u8, 'Z'), plain_file[11]);

    // too small for a wrapper
    var tiny: [wrapped_header - 1]u8 = undefined;
    try testing.expectError(error.NotWrapped, decryptWrapped(&tiny, &tkf));
}
