//! Root of `zig build test`: the modules with no VLC dependency, whose `test` blocks hold the unit tests.
//! All test data is synthetic (built in the tests).

test {
    _ = @import("hli.zig");
    _ = @import("spu.zig");
    _ = @import("udf.zig");
    _ = @import("vm.zig");
    _ = @import("ifo.zig");
    _ = @import("adv/dom.zig");
    _ = @import("adv/xpl.zig");
    _ = @import("adv/vti.zig");
    _ = @import("adv/tmap.zig");
    _ = @import("adv/aca.zig");
    _ = @import("adv/timeline.zig");
    _ = @import("adv/player.zig");
    _ = @import("adv/compose.zig");
    _ = @import("adv/mix.zig");
    _ = @import("adv/retime.zig");
    _ = @import("adv/uri.zig");
    _ = @import("adv/memfs.zig");
    _ = @import("adv/advpck.zig");
    _ = @import("adv/filecache.zig");
    _ = @import("adv/resman.zig");
    _ = @import("adv/pstore.zig");
    _ = @import("adv/manifest.zig");
    _ = @import("adv/raster.zig");
    _ = @import("adv/planes.zig");
    _ = @import("adv/engine/engine.zig");
    _ = @import("adv/engine/testpage.zig");
    _ = @import("adv/image.zig");
    _ = @import("adv/font.zig");
    _ = @import("adv/xpath.zig");
    _ = @import("adv/markup/style.zig");
    _ = @import("adv/markup/page.zig");
    _ = @import("adv/markup/layout.zig");
    _ = @import("adv/markup/paint.zig");
    _ = @import("adv/markup/apps.zig");
}
