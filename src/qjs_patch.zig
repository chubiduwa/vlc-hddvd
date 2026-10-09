//! Build tool: patches QuickJS-ng's quickjs.c for the HD DVD script profile (HD DVD Vol. 3 §8.2):
//! - no automatic semicolon insertion (§8.2.7): a missing semicolon is a syntax error, also after do-while;
//! - no `with` statement (§8.2.6), in sloppy mode too;
//! - the Function constructors throw EvalError (§8.2.3), and EvalError gets a throw helper
//!   (JS_ThrowEvalError) for the host's eval.
//!
//!   qjs_patch <quickjs.c> <output>
//!
//! Each patch must match exactly once, so a QuickJS-ng update that moves the code fails the build.

const std = @import("std");

const Patch = struct { old: []const u8, new: []const u8 };

const patches = [_]Patch{
    .{
        .old = "    X(Type, TYPE)           \\\n",
        .new = "    X(Type, TYPE)           \\\n    X(Eval, EVAL)           \\\n",
    },
    .{
        .old =
        \\        /* automatic insertion of ';' */
        \\        if (s->token.val == TOK_EOF || s->token.val == '}' || s->got_lf) {
        \\            return 0;
        \\        }
        \\
        ,
        .new = "",
    },
    .{
        .old =
        \\            /* Insert semicolon if missing */
        \\            if (s->token.val == ';') {
        \\                if (next_token(s))
        \\                    goto fail;
        \\            }
        \\
        ,
        .new =
        \\            if (js_parse_expect_semi(s))
        \\                goto fail;
        \\
        ,
    },
    .{
        .old =
        \\    case TOK_WITH:
        \\        if (s->cur_func->is_strict_mode) {
        ,
        .new =
        \\    case TOK_WITH:
        \\        if (true) {
        ,
    },
    .{
        .old =
        \\    JSFunctionKindEnum func_kind = magic;
        \\    int i, n, ret;
        \\    JSValue s, proto, obj = JS_UNDEFINED;
        \\    StringBuffer b_s, *b = &b_s;
        \\
        ,
        .new =
        \\    JSFunctionKindEnum func_kind = magic;
        \\    int i, n, ret;
        \\    JSValue s, proto, obj = JS_UNDEFINED;
        \\    StringBuffer b_s, *b = &b_s;
        \\
        \\    if (true)
        \\        return JS_ThrowEvalError(ctx, "Function constructor is not supported");
        \\
        ,
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    var src = try cwd.readFileAlloc(init.io, args[1], arena, .limited(16 << 20));
    for (patches) |p| {
        const at = std.mem.indexOf(u8, src, p.old) orelse {
            std.debug.print("qjs_patch: no match for:\n{s}\n", .{p.old});
            return error.PatchFailed;
        };
        if (std.mem.indexOfPos(u8, src, at + 1, p.old) != null) {
            std.debug.print("qjs_patch: several matches for:\n{s}\n", .{p.old});
            return error.PatchFailed;
        }
        src = try std.mem.concat(arena, u8, &.{ src[0..at], p.new, src[at + p.old.len ..] });
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = src });
}
