//! Virtual key codes of user input events (HD DVD Annex V, Table V-1), with their names as accessKey
//! attributes and scripts write them. No VLC dependency.

const std = @import("std");

pub const Key = u8;

const Entry = struct { name: []const u8, code: Key };

pub const table = [_]Entry{
    .{ .name = "VK_PLAY", .code = 0xFA },
    .{ .name = "VK_PAUSE", .code = 0xB3 },
    .{ .name = "VK_FF", .code = 0xC1 },
    .{ .name = "VK_FR", .code = 0xC2 },
    .{ .name = "VK_SF", .code = 0xC3 },
    .{ .name = "VK_SR", .code = 0xC4 },
    .{ .name = "VK_STEP_NEXT", .code = 0xC5 },
    .{ .name = "VK_STEP_PREV", .code = 0xC6 },
    .{ .name = "VK_SKIP_NEXT", .code = 0xC7 },
    .{ .name = "VK_SKIP_PREV", .code = 0xC8 },
    .{ .name = "VK_SUBTITLE_SWITCH", .code = 0xC9 },
    .{ .name = "VK_SUBTITLE", .code = 0xCA },
    .{ .name = "VK_CC", .code = 0xCB },
    .{ .name = "VK_ANGLE", .code = 0xCC },
    .{ .name = "VK_AUDIO", .code = 0xCD },
    .{ .name = "VK_MENU", .code = 0xCE },
    .{ .name = "VK_TOP_MENU", .code = 0xCF },
    .{ .name = "VK_BACK", .code = 0xD0 },
    .{ .name = "VK_RESUME", .code = 0xD1 },
    .{ .name = "VK_LEFT", .code = 0x25 },
    .{ .name = "VK_UP", .code = 0x26 },
    .{ .name = "VK_RIGHT", .code = 0x27 },
    .{ .name = "VK_DOWN", .code = 0x28 },
    .{ .name = "VK_LEFTUP", .code = 0x29 },
    .{ .name = "VK_RIGHTUP", .code = 0x2A },
    .{ .name = "VK_LEFTDOWN", .code = 0x2B },
    .{ .name = "VK_RIGHTDOWN", .code = 0x2C },
    .{ .name = "VK_TAB", .code = 0x09 },
    .{ .name = "VK_A_BUTTON", .code = 0x70 },
    .{ .name = "VK_B_BUTTON", .code = 0x71 },
    .{ .name = "VK_C_BUTTON", .code = 0x72 },
    .{ .name = "VK_D_BUTTON", .code = 0x73 },
    .{ .name = "VK_E_BUTTON", .code = 0x74 },
    .{ .name = "VK_F_BUTTON", .code = 0x75 },
    .{ .name = "VK_G_BUTTON", .code = 0x76 },
    .{ .name = "VK_H_BUTTON", .code = 0x77 },
    .{ .name = "VK_I_BUTTON", .code = 0x78 },
    .{ .name = "VK_J_BUTTON", .code = 0x79 },
    .{ .name = "VK_K_BUTTON", .code = 0x7A },
    .{ .name = "VK_L_BUTTON", .code = 0x7B },
    .{ .name = "VK_ENTER", .code = 0x0D },
    .{ .name = "VK_ESC", .code = 0x1B },
    .{ .name = "VK_0", .code = 0x30 },
    .{ .name = "VK_1", .code = 0x31 },
    .{ .name = "VK_2", .code = 0x32 },
    .{ .name = "VK_3", .code = 0x33 },
    .{ .name = "VK_4", .code = 0x34 },
    .{ .name = "VK_5", .code = 0x35 },
    .{ .name = "VK_6", .code = 0x36 },
    .{ .name = "VK_7", .code = 0x37 },
    .{ .name = "VK_8", .code = 0x38 },
    .{ .name = "VK_9", .code = 0x39 },
    .{ .name = "VK_MOUSE_1", .code = 0x01 },
    .{ .name = "VK_MOUSE_2", .code = 0x02 },
    .{ .name = "VK_MOUSE_3", .code = 0x04 },
    .{ .name = "VK_MOUSE_4", .code = 0x05 },
    .{ .name = "VK_MOUSE_5", .code = 0x06 },
    .{ .name = "VK_VECTOR_1", .code = 0x97 },
    .{ .name = "VK_VECTOR_2", .code = 0x98 },
    .{ .name = "VK_VECTOR_3", .code = 0x99 },
    .{ .name = "VK_VECTOR_4", .code = 0x9A },
};

pub const enter: Key = 0x0D;
pub const esc: Key = 0x1B;
pub const left: Key = 0x25;
pub const up: Key = 0x26;
pub const right: Key = 0x27;
pub const down: Key = 0x28;
pub const left_up: Key = 0x29;
pub const right_up: Key = 0x2A;
pub const left_down: Key = 0x2B;
pub const right_down: Key = 0x2C;
pub const menu: Key = 0xCE;
pub const top_menu: Key = 0xCF;
pub const mouse_1: Key = 0x01;

pub fn byName(n: []const u8) ?Key {
    for (table) |t| if (std.mem.eql(u8, t.name, n)) return t.code;
    return null;
}

pub fn name(code: Key) ?[]const u8 {
    for (table) |t| if (t.code == code) return t.name;
    return null;
}

/// The character a key produces, for `U+XXXX` accessKeys: the digit keys produce their digits.
pub fn char(code: Key) ?u21 {
    return if (code >= 0x30 and code <= 0x39) code else null;
}

/// Whether `code` matches one item of an accessKey list (§7.5.3.2.1): a key name, or `U+` and the hex code
/// point of the character the key produces.
pub fn matches(list: []const u8, code: Key) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |item| {
        if (item.len > 2 and (item[0] == 'U' or item[0] == 'u') and item[1] == '+') {
            const cp = std.fmt.parseInt(u21, item[2..], 16) catch continue;
            if (char(code) == cp) return true;
        } else if (byName(item) == code) return true;
    }
    return false;
}

test "access keys" {
    try std.testing.expect(matches("VK_LEFT", left));
    try std.testing.expect(matches("U+0030 U+0031", 0x31));
    try std.testing.expect(!matches("U+0041 VK_ENTER", left));
    try std.testing.expect(matches("bogus  VK_ENTER ", enter));
    try std.testing.expectEqualStrings("VK_TOP_MENU", name(top_menu).?);
}
