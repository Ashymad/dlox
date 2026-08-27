const std = @import("std");

pub fn Array(comptime T: type, comptime S: type, comptime size: S) type {
    return struct {
        len: S,
        data: []T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return @This(){ .len = 0, .data = try allocator.alloc(T, size), .allocator = allocator };
        }

        pub fn add(self: *@This(), val: T) !void {
            if (self.data.len <= self.len) {
                self.data = try self.allocator.realloc(self.data, 2 * self.data.len);
            }
            self.data[self.len] = val;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.data[0..self.len];
        }

        pub fn get(self: *const @This(), idx: S) !T {
            if (idx >= self.len)
                return error.IndexOutOfBounds;
            return self.data[idx];
        }

        pub fn if_get(self: *const @This(), idx: S) ?T {
            if (idx >= self.len)
                return null;
            return self.data[idx];
        }

        pub fn set(self: *const @This(), idx: S, val: T) !void {
            if (idx >= self.len)
                return error.IndexOutOfBounds;
            self.data[idx] = val;
        }

        pub fn last(self: *const @This()) !T {
            if (self.len == 0)
                return error.IndexOutOfBounds;
            return self.data[self.len - 1];
        }

        pub fn if_last(self: *const @This()) ?T {
            if (self.len == 0)
                return null;
            return self.data[self.len - 1];
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.data);
        }
    };
}

pub fn RLEArray(comptime T: type, comptime size: usize) type {
    return struct {
        array: Array(element, usize, size),

        const element = struct { val: T, run: usize };

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return @This(){
                .array = try Array(element, usize, size).init(allocator),
            };
        }

        pub fn add(self: *@This(), val: T) !void {
            const last = self.array.last() catch {
                try self.array.add(.{ .val = val, .run = 1 });
                return;
            };
            if (val == last.val) {
                self.array.data[self.array.len - 1].run += 1;
            } else {
                try self.array.add(.{ .val = val, .run = 1 });
            }
        }

        pub fn get(self: *const @This(), idx: usize) !T {
            var i: usize = 0;
            var sum: usize = 0;
            while (idx >= sum) : (i += 1) {
                sum += (try self.array.get(i)).run;
            }
            if (i > 0) return self.array.data[i - 1].val else return (try self.array.get(i)).val;
        }

        pub fn deinit(self: *@This()) void {
            self.array.deinit();
        }
    };
}
