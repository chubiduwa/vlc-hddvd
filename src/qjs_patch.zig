//! Build tool: patches QuickJS-ng's quickjs.c for the HD DVD script profile (HD DVD Vol. 3 §8.2):
//! - no automatic semicolon insertion (§8.2.7): a missing semicolon is a syntax error, also after do-while;
//! - no `with` statement (§8.2.6), in sloppy mode too;
//! - the Function constructors throw EvalError (§8.2.3), and EvalError gets a throw helper
//!   (JS_ThrowEvalError) for the host's eval;
//! - `f.arguments` and `f.caller` of a running non-strict function, as SpiderMonkey and JScript had them (disc
//!   menus read `Command.arguments`); null when it is not running;
//! - a hook called on every throw, caught or not (`js_throw_hook`, for debugging scripts that catch everything).
//!
//!   qjs_patch <quickjs.c> <output>
//!
//! Each patch must match exactly once, so a QuickJS-ng update that moves the code fails the build.

const std = @import("std");

const Patch = struct { old: []const u8, new: []const u8 };

const patches = [_]Patch{
    .{
        .old =
        \\static JSValue js_function_proto_fileName(JSContext *ctx,
        ,
        .new =
        \\static JSValue js_build_arguments(JSContext *ctx, int argc, JSValueConst *argv);
        \\
        \\/* f.arguments and f.caller (SpiderMonkey/JScript): the innermost active call of non-strict f. A call
        \\   with fewer arguments than parameters shows the parameter count (QuickJS pads the frame). */
        \\static JSStackFrame *hddvd_active_frame(JSContext *ctx, JSValueConst f)
        \\{
        \\    JSStackFrame *sf;
        \\    for (sf = ctx->rt->current_stack_frame; sf; sf = sf->prev_frame) {
        \\        if (JS_VALUE_GET_TAG(sf->cur_func) == JS_TAG_OBJECT &&
        \\            JS_VALUE_GET_OBJ(sf->cur_func) == JS_VALUE_GET_OBJ(f))
        \\            return sf;
        \\    }
        \\    return NULL;
        \\}
        \\
        \\static JSValue hddvd_function_arguments(JSContext *ctx, JSValueConst this_val,
        \\                                        int argc, JSValueConst *argv)
        \\{
        \\    JSFunctionBytecode *b = JS_GetFunctionBytecode(this_val);
        \\    JSStackFrame *sf;
        \\    if (!b || b->is_strict_mode || !b->has_prototype)
        \\        return JS_ThrowTypeError(ctx, "invalid property access");
        \\    sf = hddvd_active_frame(ctx, this_val);
        \\    if (!sf)
        \\        return JS_NULL;
        \\    return js_build_arguments(ctx, sf->arg_count, (JSValueConst *)sf->arg_buf);
        \\}
        \\
        \\static JSValue hddvd_function_caller(JSContext *ctx, JSValueConst this_val,
        \\                                     int argc, JSValueConst *argv)
        \\{
        \\    JSFunctionBytecode *b = JS_GetFunctionBytecode(this_val);
        \\    JSStackFrame *sf;
        \\    if (!b || b->is_strict_mode || !b->has_prototype)
        \\        return JS_ThrowTypeError(ctx, "invalid property access");
        \\    sf = hddvd_active_frame(ctx, this_val);
        \\    if (!sf || !sf->prev_frame || !JS_IsFunction(ctx, sf->prev_frame->cur_func))
        \\        return JS_NULL;
        \\    return js_dup(sf->prev_frame->cur_func);
        \\}
        \\
        \\static JSValue js_function_proto_fileName(JSContext *ctx,
        ,
    },
    .{
        .old =
        \\    if (JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_caller, JS_UNDEFINED,
        \\                          ctx->throw_type_error, ctx->throw_type_error,
        \\                          JS_PROP_HAS_GET | JS_PROP_HAS_SET |
        \\                          JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE) < 0)
        \\        return -1;
        \\    if (JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_arguments, JS_UNDEFINED,
        \\                          ctx->throw_type_error, ctx->throw_type_error,
        \\                          JS_PROP_HAS_GET | JS_PROP_HAS_SET |
        \\                          JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE) < 0)
        \\        return -1;
        ,
        .new =
        \\    {
        \\        JSValue get_caller = JS_NewCFunction(ctx, hddvd_function_caller, "caller", 0);
        \\        JSValue get_args = JS_NewCFunction(ctx, hddvd_function_arguments, "arguments", 0);
        \\        int r1 = JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_caller, JS_UNDEFINED,
        \\                                   get_caller, ctx->throw_type_error,
        \\                                   JS_PROP_HAS_GET | JS_PROP_HAS_SET |
        \\                                   JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE);
        \\        int r2 = JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_arguments, JS_UNDEFINED,
        \\                                   get_args, ctx->throw_type_error,
        \\                                   JS_PROP_HAS_GET | JS_PROP_HAS_SET |
        \\                                   JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE);
        \\        JS_FreeValue(ctx, get_caller);
        \\        JS_FreeValue(ctx, get_args);
        \\        if (r1 < 0 || r2 < 0)
        \\            return -1;
        \\    }
        ,
    },
    .{
        .old =
        \\JSValue JS_Throw(JSContext *ctx, JSValue obj)
        \\{
        \\    JSRuntime *rt = ctx->rt;
        \\    JS_FreeValue(ctx, rt->current_exception);
        \\    rt->current_exception = obj;
        \\    return JS_EXCEPTION;
        \\}
        ,
        .new =
        \\void (*js_throw_hook)(JSContext *ctx) = NULL;
        \\
        \\JSValue JS_Throw(JSContext *ctx, JSValue obj)
        \\{
        \\    JSRuntime *rt = ctx->rt;
        \\    JS_FreeValue(ctx, rt->current_exception);
        \\    rt->current_exception = obj;
        \\    if (js_throw_hook)
        \\        js_throw_hook(ctx);
        \\    return JS_EXCEPTION;
        \\}
        ,
    },
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
