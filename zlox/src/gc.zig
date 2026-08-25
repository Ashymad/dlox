const std = @import("std");

const list = @import("lib::list.zig");
const utils = @import("lib::utils.zig");

const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

pub const GC = struct {
    pub const Obj = @import("obj.zig").Obj(.{ .gc = true, .mark = false });

    const Self = @This();

    const ObjList = list.List(*Obj);
    const CallbackList = list.List(Callback);
    const GreyList = list.List(*Obj);

    pub const Callback = struct {
        pub const Arg = *anyopaque;
        pub const Fn = *const fn (Arg) void;

        arg: Arg,
        @"fn": Fn,

        pub fn call(self: *const @This()) void {
            self.@"fn"(self.arg);
        }
    };

    const DBG_STRESS = true;
    const DBG_LOG = true;

    allocator: std.mem.Allocator,
    io: std.Io,
    table: Obj.String.Table,
    objs: ObjList,
    callbacks: CallbackList,
    greys: GreyList,

    fn dbg_print(comptime fmt: []const u8, args: anytype) void {
        if (DBG_LOG) {
            std.debug.print("[GC] " ++ fmt, args);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .table = Obj.String.Table.init(allocator),
            .objs = ObjList.init(allocator),
            .callbacks = CallbackList.init(allocator),
            .greys = GreyList.init(allocator),
        };
    }

    fn collect(self: *Self) void {
        if (self.callbacks.len() > 0) {
            self.mark_roots();
            self.trace_references();
            self.table_remove_white();
            self.sweep();
        }
    }

    fn trace_references(self: *Self) void {
        while (true) {
            const grey = self.greys.pop(0) catch break;
            switch (grey.type) {
                inline else => |tp| self.blacken_obj(grey.cast(tp) catch unreachable),
            }
        }
    }

    fn blacken_obj(self: *Self, obj: anytype) void {
        const T = @TypeOf(obj);

        switch (T) {
            *Obj.String => {},
            *Obj.Native => {},
            *Obj.Table => {
                obj.table.ptr().for_each(self, struct {
                    pub fn fun(s: *Self, key: Obj.Table.Table.Key, val: Obj.Table.Table.Value) void {
                        s.mark("t", key);
                        s.mark("t", val);
                    }
                }.fun);
            },
            *Obj.Function => {
                if (obj.name.ptr()) |name|
                    self.mark("f", name);
                for (obj.chunk.ptr().constants.slice()) |constant|
                    self.mark("f", constant);
            },
            *Obj.List => {
                var iter = obj.list.ptr().iter();
                while (iter.next()) |val| {
                    self.mark("t", val);
                }
            },
            *Obj.Closure => {
                self.mark("c", obj.function.ptr());
                for (obj.upvalues.ptr()) |upvalue_ptr|
                    if (upvalue_ptr) |upvalue|
                        self.mark("c", upvalue);
            },
            *Obj.Upvalue => {
                if (obj.closed)
                    self.mark("u", obj.location.get());
            },
            else => @compileError("Invalid type: " ++ @typeName(T)),
        }
    }

    fn mark_roots(self: *Self) void {
        var iter = self.callbacks.iter();
        while (iter.next()) |cb|
            cb.call();
    }

    fn table_remove_white(self: *Self) void {
        const tbl = &self.table;
        tbl.for_each(tbl, struct {
            pub fn fun(table: *Obj.String.Table, key: Obj.String.Table.Key, _: Obj.String.Table.Value) void {
                const obj = key.cast();
                if (obj.fields.gc and !obj.fields.mark)
                    _ = table.delete(key);
            }
        }.fun);
    }

    fn sweep(self: *Self) void {
        var iter = self.objs.iter();
        while (iter.next()) |obj| {
            if (obj.fields.gc) {
                if (!obj.fields.mark) {
                    iter.pop();
                    dbg_obj("O", "free", obj, false);
                    obj.free(self.allocator);
                } else {
                    obj.fields.mark = false;
                }
            }
        }
    }

    pub fn push_callback(self: *Self, callback: Callback.Fn, arg: Callback.Arg) !void {
        try self.callbacks.push(0, Callback{ .@"fn" = callback, .arg = arg });
    }

    pub fn swap_callback(self: *Self, callback: Callback.Fn, arg: Callback.Arg) !void {
        try self.callbacks.set(0, Callback{ .@"fn" = callback, .arg = arg });
    }

    pub fn pop_callback(self: *Self) void {
        _ = self.callbacks.pop(0) catch return;
    }

    pub fn dbg_obj(info: []const u8, msg: []const u8, obj: anytype, comptime prin: bool) void {
        if (prin) {
            dbg_print("[{s}] {s: >5}: {s: <8} 0x{x} {f}\n", .{
                info,
                msg,
                @tagName(obj.type),
                @intFromPtr(obj),
                obj,
            });
        } else {
            dbg_print("[{s}] {s: >5}: {s: <8} 0x{x}\n", .{
                info,
                msg,
                @tagName(obj.type),
                @intFromPtr(obj),
            });
        }
    }

    pub fn emplace(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) (ObjList.Error || tp.get().Error)!*tp.get() {
        if (DBG_STRESS) {
            self.collect();
        }

        var newObj = true;
        const obj = switch (tp) {
            .String => try Obj.String.intern(arg, &self.table, &newObj, self.allocator),
            else => try tp.get().init(arg, self.allocator),
        };

        if (newObj) {
            const obj_p = obj.cast();

            dbg_obj("O", "new", obj_p, true);
            try self.objs.push(0, obj_p);
        }

        return obj;
    }

    pub fn mark(self: *Self, msg: []const u8, arg: anytype) void {
        const T = @TypeOf(arg);

        switch (T) {
            Value => switch (arg) {
                .obj => |o| {
                    self.mark(msg, o);
                },
                else => {},
            },
            *Obj => if (arg.fields.gc and !arg.fields.mark) {
                dbg_obj(msg, "mark", arg, true);
                arg.fields.mark = true;
                self.greys.push(-1, arg) catch @panic("Grey stack overflow");
            },
            else => if (comptime Obj.is_child(T)) {
                self.mark(msg, arg.cast());
            } else {
                @compileError("Unable to mark " ++ @typeName(T));
            },
        }
    }

    pub fn exclude(obj: *Obj) void {
        obj.fields.gc = false;
    }

    pub fn emplace_cast(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) (ObjList.Error || tp.get().Error)!*Obj {
        return (try self.emplace(tp, arg)).cast();
    }

    pub fn deinit(self: *Self) void {
        self.callbacks.free();
        self.greys.free();
        while (true) {
            const el = self.objs.pop(0) catch break;
            dbg_obj("O", "free", el, false);
            el.free(self.allocator);
        }
        self.objs.free();
        self.table.deinit();
    }
};
