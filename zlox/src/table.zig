const std = @import("std");
const utils = @import("comptime_utils.zig");

pub const TableError = error{ OutOfMemory, KeyError };

pub fn Table(K: type, V: type, hash_fn: fn (K) u32, cmp_fn: fn (K, K) bool) type {
    return struct {
        const Self = @This();
        const MaxLoad: f32 = 0.75;

        pub const Entry = union(enum) {
            const Some = struct {
                key: K,
                value: V,
            };
            some: Some,
            none,
            tomb,
        };

        count: usize,
        entries: []Entry,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .count = 0, .entries = &.{}, .allocator = allocator };
        }

        fn growCapacity(self: *const Self) usize {
            return if (self.entries.len > 0)
                self.entries.len * 2
            else
                10;
        }

        fn adjustCapacity(self: *Self, newsize: usize) TableError!void {
            const entries = try self.allocator.alloc(Entry, newsize);
            for (entries) |*entry| {
                entry.* = .none;
            }
            self.count = 0;
            for (self.entries) |entry| {
                switch (entry) {
                    .some => |some| {
                        find(entries, some.key).* = entry;
                        self.count += 1;
                    },
                    else => {},
                }
            }
            self.allocator.free(self.entries);
            self.entries = entries;
        }
        pub fn find_check(key: K) struct {
            k: K,
            pub fn check(self: *const @This(), k2: K) bool {
                return cmp_fn(self.k, k2);
            }
        } {
            return @TypeOf(find_check(key)){ .k = key };
        }

        pub fn find(entries: []Entry, key: K) *Entry {
            return find_(entries, hash_fn(key), find_check(key));
        }

        pub fn find_(entries: []Entry, hash: u32, check: anytype) *Entry {
            var idx = hash % entries.len;
            var tomb: ?*Entry = null;

            while (true) {
                const entry = &entries[idx];
                switch (entry.*) {
                    .some => |some| if (check.check(some.key)) return entry,
                    .tomb => tomb = if (tomb) |t| t else entry,
                    .none => return if (tomb) |t| t else entry,
                }
                idx = (idx + 1) % entries.len;
            }
        }

        pub fn addAll(self: *Self, other: *const Self) TableError!void {
            for (other.entries) |entry| {
                switch (entry) {
                    .some => |some| self.set(some.key, some.value),
                    else => {},
                }
            }
        }

        pub fn for_each(self: *const Self, arg: anytype, fun: fn (@TypeOf(arg), K, V) void) void {
            for (self.entries) |entry| {
                switch (entry) {
                    .some => |some| fun(arg, some.key, some.value),
                    else => {},
                }
            }
        }

        pub fn for_each_try(self: *const Self, arg: anytype, fun: anytype) utils.fn_error(fun)!void {
            for (self.entries) |entry| {
                switch (entry) {
                    .some => |some| try fun(arg, some.key, some.value),
                    else => {},
                }
            }
        }

        pub fn set_(self: *Self, entry: *Entry, key: K, val: V) bool {
            const isNewKey = switch (entry.*) {
                .none => blk: {
                    self.count += 1;
                    break :blk true;
                },
                .tomb => true,
                .some => false,
            };

            entry.* = Entry{ .some = Entry.Some{ .key = key, .value = val } };
            return isNewKey;
        }

        pub fn eql(self: *const Self, other: *const Self, cmpval_fn: fn (V, V) bool) bool {
            for (self.entries) |entry| {
                switch (entry) {
                    .some => |some| {
                        switch (find(other.entries, some.key).*) {
                            .some => |some2| if (!cmpval_fn(some.value, some2.value)) {
                                return false;
                            },
                            else => return false,
                        }
                    },
                    else => {},
                }
            }
            return true;
        }

        pub fn checkCapacity(self: *Self) TableError!void {
            const len: f32 = @floatFromInt(self.entries.len);
            const count: f32 = @floatFromInt(self.count);
            if (count + 1.0 > len * MaxLoad) {
                try self.adjustCapacity(self.growCapacity());
            }
        }

        pub fn set(self: *Self, key: K, val: V) TableError!bool {
            try self.checkCapacity();
            return self.set_(find(self.entries, key), key, val);
        }

        pub fn replace(self: *Self, key: K, val: V) TableError!void {
            if (self.entries.len == 0)
                return TableError.KeyError;

            const entry = find(self.entries, key);
            switch (entry.*) {
                .some => _ = self.set_(entry, key, val),
                else => return TableError.KeyError,
            }
        }

        pub fn replace_if(self: *Self, key: K, val: V, fun: fn (V) bool) TableError!bool {
            if (self.entries.len == 0)
                return TableError.KeyError;

            const entry = find(self.entries, key);
            switch (entry.*) {
                .some => |some| return fun(some.value) and !self.set_(entry, key, val),
                else => return TableError.KeyError,
            }
        }

        pub fn get(self: *const Self, key: K) TableError!V {
            if (self.entries.len == 0)
                return TableError.KeyError;

            return switch (find(self.entries, key).*) {
                .some => |some| some.value,
                else => TableError.KeyError,
            };
        }

        pub fn delete(self: *Self, key: K) bool {
            if (self.entries.len == 0) return false;

            const entry = find(self.entries, key);
            switch (entry.*) {
                .some => entry.* = .tomb,
                else => return false,
            }

            return true;
        }

        pub fn deinit(self: *@This()) void {
            if (self.entries.len > 0) {
                self.allocator.free(self.entries);
                self.entries = &.{};
                self.count = 0;
            }
        }
    };
}
