const std = @import("std");

const list = @import("lib::list.zig");
const utils = @import("lib::utils.zig");

const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

pub const GC = struct {
    pub const Color = enum(u8) {
        White,
        Black,
        None,
    };

    pub const Obj = @import("obj.zig").Obj(.{ .color = Color.White });

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

    const DBG_STRESS = false;
    const DBG_LOG = false;
    const GC_HEAP_GROW_FACTOR = 2;

    allocator: std.mem.Allocator,
    io: std.Io,
    pool: Obj.String.Pool,
    objs: ObjList,
    callbacks: CallbackList,
    greys: GreyList,
    allocated: usize,
    next: usize,

    fn dbg_print(comptime fmt: []const u8, args: anytype) void {
        if (DBG_LOG) {
            std.debug.print("[GC] " ++ fmt, args);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .pool = Obj.String.Pool.init(allocator),
            .objs = ObjList.init(allocator),
            .callbacks = CallbackList.init(allocator),
            .greys = GreyList.init(allocator),
            .allocated = 0,
            .next = 1024 * 1024,
        };
    }

    pub fn collect(self: *Self) void {
        if (self.callbacks.len() > 0) {
            self.mark_roots();
            self.trace_references();
            self.table_remove_white();
            self.sweep();
            self.next = self.allocated * GC_HEAP_GROW_FACTOR;
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
            *Obj.Table => {
                obj.table.ptr().for_each(self, struct {
                    pub fn fun(s: *Self, key: Obj.Table.Table.Key, val: Obj.Table.Table.Value) void {
                        s.mark("t", key);
                        s.mark("t", val);
                    }
                }.fun);
            },
            *Obj.Function => {
                self.mark("f", obj.chunk.ptr());
                if (obj.upvalues.ptr()) |upvalues|
                    for (upvalues) |upvalue_ptr|
                        if (upvalue_ptr) |upvalue|
                            self.mark("c", upvalue);
            },
            *Obj.Chunk => {
                for (obj.constants.ptr().slice()) |constant|
                    self.mark("h", constant);
            },
            *Obj.List => {
                var iter = obj.list.ptr().iter();
                while (iter.next()) |val| {
                    self.mark("l", val);
                }
            },
            *Obj.Upvalue => {
                if (obj.closed)
                    self.mark("u", obj.location.get());
            },
            *Obj.Instance => {
                self.mark("i", obj.cls.ptr());
                obj.fields.ptr().for_each(self, struct {
                    pub fn fun(s: *Self, key: Obj.Instance.Fields.Key, val: Obj.Instance.Fields.Value) void {
                        s.mark("i", key);
                        s.mark("i", val);
                    }
                }.fun);
            },
            *Obj.Class => {
                obj.methods.ptr().for_each(self, struct {
                    pub fn fun(s: *Self, key: Obj.Class.Methods.Key, val: Obj.Class.Methods.Value) void {
                        s.mark("k", key);
                        s.mark("k", val);
                    }
                }.fun);
            },
            else => {},
        }
    }

    fn mark_roots(self: *Self) void {
        var iter = self.callbacks.iter();
        while (iter.next()) |cb|
            cb.call();
    }

    fn table_remove_white(self: *Self) void {
        const Table = Obj.String.Pool.Table;
        const table = &self.pool.table;

        table.for_each(table, struct {
            pub fn fun(tbl: *Table, key: Table.Key, _: Table.Value) void {
                const obj = key.cast();
                if (obj.fields.color == .White)
                    _ = tbl.delete(key);
            }
        }.fun);
    }

    fn sweep(self: *Self) void {
        var iter = self.objs.iter();
        while (iter.next()) |obj| {
            if (obj.fields.color == .White) {
                iter.pop();
                dbg_obj("O", "free", obj, false);
                switch (obj.type) {
                    inline else => |tp| self.allocated -= @sizeOf(tp.get()),
                }
                if (obj.cast_if(.String)) |str| self.allocated -= str.len;
                obj.free(self.allocator);
            } else if (obj.fields.color == .Black) {
                obj.fields.color = .White;
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

    pub fn emplace(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) (ObjList.Error || tp.get().Error || Obj.String.Pool.Error)!*tp.get() {
        if (tp == .String)
            if (self.pool.find(arg)) |obj|
                return obj;

        const chd = try tp.get().init(arg, self.allocator);

        self.allocated += @sizeOf(tp.get());
        if (tp == .String) self.allocated += chd.len;

        if (DBG_STRESS or self.allocated > self.next) {
            self.collect();
        }

        if (tp == .String)
            try self.pool.put(chd);

        const obj = chd.cast();
        dbg_obj("O", "new", obj, true);

        try self.objs.push(0, obj);

        return chd;
    }

    pub fn mark(self: *Self, msg: []const u8, arg: anytype) void {
        if (Obj.from(arg)) |obj| {
            if (obj.fields.color == .White) {
                dbg_obj(msg, "mark", obj, true);
                obj.fields.color = .Black;
                self.greys.push(-1, obj) catch @panic("Grey stack overflow");
            }
        }
    }

    pub fn exclude(obj: *Obj) void {
        obj.fields.color = .None;
    }

    pub fn emplace_cast(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) !*Obj {
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
        self.pool.free();
    }
};
