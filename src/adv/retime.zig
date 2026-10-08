//! Frame times for decoded video. HD DVD EVOBs carry a presentation time stamp only on the first video access
//! unit of each EVOBU (about every half second); the frames in between must be timed by their field counts
//! (3:2 pulldown repeats a field every other frame). VLC 3's decoders interpolate with a fixed frame duration,
//! so frames drift by up to a field and snap back at the next timestamp: a visible hitch every EVOBU.
//! This recomputes each frame's date from the previous one and its field count. No VLC dependency.

const std = @import("std");

pub const Retimer = struct {
    /// Duration of one field (µs), from the stream's frame rate.
    field_us: i64,
    /// Date the next frame should have, or null to take the next frame's own date.
    next: ?i64 = null,

    /// `num/den` frames per second (as in video_format_t: i_frame_rate / i_frame_rate_base).
    pub fn init(num: u32, den: u32) Retimer {
        const n: i64 = if (num == 0) 30000 else num;
        const d: i64 = if (num == 0) 1001 else @max(1, den);
        return .{ .field_us = @divTrunc(d * 1_000_000, 2 * n) };
    }

    pub fn reset(r: *Retimer) void {
        r.next = null;
    }

    /// The corrected date of a frame the decoder dated `date` and that lasts `fields` fields.
    ///
    /// A date within a quarter field of the expected one is a real timestamp (or a correct interpolation):
    /// taken as is, so the cadence follows the stream. A date further than a few frames away is a
    /// discontinuity: re-anchored there. Anything else is the decoder's interpolation: replaced.
    pub fn frame(r: *Retimer, date: i64, fields: u32) i64 {
        const f: i64 = if (fields == 0) 2 else fields;
        const out = if (r.next) |n| blk: {
            const diff = date - n;
            if (@abs(diff) <= @divTrunc(r.field_us, 4)) break :blk date;
            if (@abs(diff) > 8 * r.field_us) break :blk date;
            break :blk n;
        } else date;
        r.next = out + f * r.field_us;
        return out;
    }
};

// ---- tests --------------------------------------------------------------------------------------------------

const testing = std.testing;

test "3:2 pulldown cadence from field counts" {
    var r = Retimer.init(30000, 1001); // 59.94 fields per second
    try testing.expectEqual(@as(i64, 16683), r.field_us);
    // As VLC dates them: a timestamp, then fixed 33.4 ms steps (wrong), then the next timestamp.
    const dates = [_]i64{ 1_000_000, 1_033_366, 1_066_732, 1_100_098, 1_216_896 };
    const fields = [_]u32{ 2, 3, 2, 3, 2 };
    var got: [5]i64 = undefined;
    for (dates, fields, 0..) |d, f, i| got[i] = r.frame(d, f);
    // 2 fields = 33.4 ms, 3 fields = 50 ms.
    try testing.expectEqual(@as(i64, 1_000_000), got[0]);
    try testing.expectEqual(@as(i64, 1_033_366), got[1]);
    try testing.expectEqual(@as(i64, 1_083_415), got[2]);
    try testing.expectEqual(@as(i64, 1_116_781), got[3]);
    // The next real timestamp (1_166_830 expected) arrives as 1_216_896 here: too far for a timestamp of this
    // cadence and too close for a discontinuity, so it is the expected time.
    try testing.expectEqual(@as(i64, 1_166_830), got[4]);
}

test "real timestamps are followed and jumps re-anchor" {
    var r = Retimer.init(24000, 1001); // progressive 23.976: 2 fields = 41.7 ms
    try testing.expectEqual(@as(i64, 1_000_000), r.frame(1_000_000, 2));
    try testing.expectEqual(@as(i64, 1_041_700), r.frame(1_041_700, 2)); // within a quarter field: taken
    try testing.expectEqual(@as(i64, 5_000_000), r.frame(5_000_000, 2)); // a seek
    r.reset();
    try testing.expectEqual(@as(i64, 42), r.frame(42, 0));
}
