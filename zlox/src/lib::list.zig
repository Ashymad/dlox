const std = @import("std");

const utils = @import("lib::utils.zig");

pub fn List(T: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, IndexOutOfBounds, Empty };
        pub const Value = T;

        const Element = struct {
            val: Value,
            next: *@This(),
            prev: *@This(),

            fn jmp(self: *Element, idx: isize) *Element {
                var ret = self;

                for (0..@abs(idx)) |_| {
                    ret = if (idx > 0) ret.next else ret.prev;
                }

                return ret;
            }

            pub fn del(self: *Element, gpa: std.mem.Allocator) void {
                self.next.prev = self.prev;
                self.prev.next = self.next;

                gpa.destroy(self);
            }

            fn init(gpa: std.mem.Allocator, prv: ?*Element, nxt: ?*Element, val: Value) !*Element {
                const ret = try gpa.create(Element);
                ret.* = Element{
                    .prev = prv orelse ret,
                    .next = nxt orelse ret,
                    .val = val,
                };
                return ret;
            }

            pub fn add_prev(self: *Element, gpa: std.mem.Allocator, val: Value) !*Element {
                self.prev.next = try Element.init(gpa, self.prev, self, val);
                self.prev = self.prev.next;
                if (self.next == self) self.next = self.prev;
                return self.prev;
            }

            pub fn add_next(self: *Element, gpa: std.mem.Allocator, val: Value) !*Element {
                self.next.prev = try Element.init(gpa, self, self.next, val);
                self.next = self.next.prev;
                if (self.prev == self) self.prev = self.next;
                return self.next;
            }

            pub fn new(gpa: std.mem.Allocator, val: Value) !*Element {
                return try Element.init(gpa, null, null, val);
            }
        };

        pub fn Iterator(@"const": bool) type {
            return struct {
                const Super = utils.mod_ptr_t(*Self, "const", @"const");
                const This = utils.mod_ptr_t(*Element, "const", @"const");

                super: Super,
                this: ?This,

                pub fn new(sup: Super) @This() {
                    return .{
                        .super = sup,
                        .this = sup.tip,
                    };
                }

                pub fn next(self: *@This()) ?Value {
                    if (self.this) |el| {
                        self.this = if (el.next == self.super.tip) null else el.next;
                        return el.val;
                    } else {
                        return null;
                    }
                }

                pub fn pop(self: *@This()) void {
                    if (@"const") @compileError("Cannot call pop() on a const Iterator");

                    const el = if (self.this) |el| el.prev else self.super.tip orelse return;

                    if (self.this == el) self.this = null;

                    self.super.del(el);
                }

                pub fn push(self: *@This(), val: Value) !void {
                    if (@"const") @compileError("Cannot call push() on a const Iterator");

                    if (self.this) |el| {
                        self.super.retip(el, try self.super.insert(.prev, el, val));
                    } else if (self.super.tip) |el| {
                        _ = try self.super.insert(.prev, el, val);
                    } else {
                        try self.super.begin(val);
                    }
                }
            };
        }

        _len: isize,
        tip: ?*Element,

        gpa: std.mem.Allocator,

        pub fn iter(self: anytype) Iterator(utils.is_const(@TypeOf(self))) {
            return Iterator(utils.is_const(@TypeOf(self))).new(self);
        }

        pub fn init(gpa: std.mem.Allocator) Self {
            return Self{
                ._len = 0,
                .tip = null,
                .gpa = gpa,
            };
        }

        pub fn len(self: *const Self) usize {
            return @intCast(self._len);
        }

        pub fn eql(self: *const Self, other: *const Self, eql_fn: fn (Value, Value) bool) bool {
            if (self._len != other._len) return false;

            var iter1 = self.iter();
            var iter2 = other.iter();

            while (iter1.next()) |val1| {
                if (!eql_fn(val1, iter2.next().?)) return false;
            }

            return true;
        }

        pub fn deinit(self: *Self) void {
            while (true) {
                _ = self.pop(-1) catch break;
            }
        }

        fn _at(self: *Self, idx: isize) Error!*Element {
            if (self.tip) |tip| {
                const haf: isize = utils.sign(idx) * @divTrunc(self._len, 2);
                return tip.jmp(@rem(idx + haf, self._len) - haf);
            } else {
                return Error.Empty;
            }
        }

        fn at(self: *Self, idx: isize) Error!*Element {
            return if (-self._len <= idx and idx < self._len)
                try self._at(idx)
            else
                Error.IndexOutOfBounds;
        }

        pub fn set(self: *Self, idx: isize, val: Value) Error!void {
            (try self.at(idx)).val = val;
        }

        pub fn get(self: *Self, idx: isize) Error!Value {
            return (try self.at(idx)).val;
        }

        fn del(self: *Self, el: *Element) void {
            self._len -= 1;

            if (self.tip == el) {
                self.tip = if (el.next == el) null else el.next;
            }

            el.del(self.gpa);
        }

        pub fn pop(self: *Self, idx: isize) Error!Value {
            const el = try self.at(idx);
            const ret = el.val;

            self.del(el);

            return ret;
        }

        fn begin(self: *Self, val: Value) !void {
            if (self.tip) |_| @panic("This function can only be called on an empty list");

            self.tip = try Element.new(self.gpa, val);
            self._len = 1;
        }

        fn insert(self: *Self, dir: enum { next, prev }, anchor: *Element, val: Value) !*Element {
            const new = if (dir == .next)
                try anchor.add_next(self.gpa, val)
            else
                try anchor.add_prev(self.gpa, val);

            self._len += 1;

            return new;
        }

        fn retip(self: *Self, old: ?*Element, new: *Element) void {
            if (self.tip == old) self.tip = new;
        }

        pub fn push(self: *Self, idx: isize, val: Value) Error!void {
            const len1 = self._len + 1;

            if (-len1 <= idx and idx < len1) {
                const el = self._at(idx) catch return self.begin(val);

                const new = try self.insert(if (idx < 0) .next else .prev, el, val);

                if (idx == -len1 or idx == 0) {
                    self.tip = new;
                }
            } else {
                return Error.IndexOutOfBounds;
            }
        }
    };
}
