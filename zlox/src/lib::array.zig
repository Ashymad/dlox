const std = @import("std");

pub fn Array(comptime T: type) type {
    return struct {
        const Self = @This();
        const Init = 8;

        len: usize,
        data: []T,
        allocator: std.mem.Allocator,

        pub const Iterator = struct {
            cur: ?[*]T = null,
            end: ?[*]T = null,

            pub fn next(self: *Iterator) ?*const T {
                if (self.cur) |cur| {
                    self.cur = if (cur == self.end)
                        null
                    else
                        cur + 1;
                    return cur[0];
                }
                return null;
            }
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .len = 0,
                .data = try allocator.alloc(T, Init),
                .allocator = allocator,
            };
        }

        pub fn iter(self: *Self) Iterator {
            return if (self.len == 0) Iterator{} else Iterator{
                .cur = &self.data[0],
                .end = &self.data[self.len - 1],
            };
        }

        pub fn add(self: *Self, val: T) !void {
            if (self.data.len <= self.len) {
                self.data = try self.allocator.realloc(self.data, 2 * self.data.len);
            }
            self.data[self.len] = val;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.data[0..self.len];
        }

        pub fn get(self: *const Self, idx: usize) ?T {
            return if (idx >= self.len) null else self.data[idx];
        }

        pub fn set(self: *const Self, idx: usize, val: T) !void {
            if (idx >= self.len)
                return error.IndexOutOfBounds;
            self.data[idx] = val;
        }

        pub fn last(self: *const Self) ?T {
            return if (self.len == 0) null else self.data[self.len - 1];
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }
    };
}
