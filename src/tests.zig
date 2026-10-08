//! Root of `zig build test`: the modules with no VLC dependency, whose `test` blocks hold the unit tests.
//! All test data is synthetic (built in the tests).

test {
    _ = @import("hli.zig");
    _ = @import("spu.zig");
    _ = @import("udf.zig");
    _ = @import("vm.zig");
    _ = @import("ifo.zig");
}
