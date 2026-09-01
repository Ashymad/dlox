const std = @import("std");

const GC = @import("gc.zig").GC;
const Value = @import("value.zig").Value;

pub const Error = GC.Obj.Native.Error;

pub const Clock = struct {
    var start: std.Io.Timestamp = undefined;

    pub fn set_start(io: std.Io) void {
        start = std.Io.Timestamp.now(io, std.Io.Clock.awake);
    }

    pub fn clock(gc: *GC, _: []const Value) Error!Value {
        return Value.init(@as(f64, @floatFromInt(std.Io.Timestamp.untilNow(start, gc.io, std.Io.Clock.awake).toMilliseconds())));
    }
};

pub fn put(_: *GC, args: []const Value) Error!Value {
    std.debug.print("{f}", .{args[0]});
    return Value.init({});
}

pub fn table(gc: *GC, args: []const Value) Error!Value {
    var tbl = gc.emplace(.Table, {}) catch return Error.Native;
    if (args.len % 2 != 0) return Error.Native;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        _ = tbl.set(args[i], args[i + 1]) catch return Error.Native;
    }
    return Value.init(tbl.cast());
}

pub fn list(gc: *GC, args: []const Value) Error!Value {
    var lis = gc.emplace(.List, {}) catch return Error.Native;
    for (args) |arg| {
        lis.list.ptr().push(-1, arg) catch return Error.Native;
    }
    return Value.init(lis.cast());
}

pub fn typeof(gc: *GC, args: []const Value) Error!Value {
    return Value.init(gc.emplace_cast(.String, &.{args[0].typeName()}) catch return Error.Native);
}

pub fn rungc(gc: *GC, _: []const Value) Error!Value {
    gc.collect();
    return Value.init({});
}

pub fn len(_: *GC, val: []const Value) Error!Value {
    if (val[0].cast_if(Value.obj)) |obj| {
        const ret = switch (obj.type) {
            .String => (obj.cast(.String) catch unreachable).len,
            .Table => (obj.cast(.Table) catch unreachable).table.ptr().count,
            .List => (obj.cast(.List) catch unreachable).list.ptr().len(),
            else => return Error.Native,
        };
        return Value.init(@as(f64, @floatFromInt(ret)));
    }
    return Error.Native;
}
