const std = @import("std");

const table = @import("lib::table.zig");
const utils = @import("lib::utils.zig");
const hash = @import("hash.zig");
const value = @import("value.zig");

const Obj = @import("obj.zig").Obj;

pub fn String(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = []const []const u8;
        pub const Error = error{ OutOfMemory, IndexOutOfBounds };

        pub const Pool = struct {
            pub const Table = table.Table(*Self, void, hash.hash_t(*const Self), Self.eql);
            pub const Error = Table.Error;

            table: Table,

            pub fn init(allocator: std.mem.Allocator) Pool {
                return .{ .table = Table.init(allocator) };
            }

            fn check(arg: Arg, len: usize, hsh: u32) struct {
                arg: Arg,
                len: usize,
                hash: u32,

                pub fn check(self: *const @This(), other: *const Self) bool {
                    if (other.hash == self.hash and other.len == self.len) {
                        var idx: usize = 0;
                        for (self.arg) |el| {
                            if (!std.mem.eql(u8, other.data()[idx .. idx + el.len], el))
                                return false;
                            idx += el.len;
                        }
                        return true;
                    }
                    return false;
                }
            } {
                return @TypeOf(check(arg, len, hsh)){
                    .arg = arg,
                    .len = len,
                    .hash = hsh,
                };
            }

            pub fn put(self: *Pool, str: *Self) !void {
                _ = try self.table.set(str, {});
            }

            pub fn find(self: *Pool, arg: Arg) ?*Self {
                if (self.table.count == 0) return null;

                const pre = Self.prehash(arg);

                const entry = Table.find_(self.table.entries, pre.hash, check(arg, pre.len, pre.hash));

                return if (entry.* != .some) null else entry.some.key;
            }

            pub fn free(self: *Pool) void {
                self.table.deinit();
            }
        };

        obj: Super,
        len: usize = 0,
        hash: u32,

        fn data(self: anytype) utils.copy_const(@TypeOf(self), [*]u8) {
            const p: utils.copy_const(@TypeOf(self), [*]u8) = @ptrCast(self);
            return p + @sizeOf(Self);
        }

        fn new(arg: Arg, len: usize, hsh: u32, allocator: std.mem.Allocator) Error!*Self {
            const ret: *Self = @ptrCast(try allocator.alignedAlloc(u8, std.mem.Alignment.of(Self), @sizeOf(Self) + len));
            ret.* = Self{
                .obj = Super.make(Self),
                .hash = hsh,
            };
            for (arg) |el| {
                @memcpy(ret.data() + ret.len, el);
                ret.len += el.len;
            }
            return ret;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.data()[0..self.len];
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.writeAll(self.slice());
        }
        pub fn eql(self: *const Self, other: *const Self) bool {
            return @intFromPtr(self) == @intFromPtr(other);
        }
        pub fn get(self: *const Self, index: value.Value) Error!value.Value {
            if (!index.is(value.Value.number) or index.number >= @as(
                value.Value.tagType(value.Value.number),
                @floatFromInt(self.len),
            ) or index.number < 0) {
                return Error.IndexOutOfBounds;
            }
            return value.Value.init(self.data()[@intFromFloat(index.number)]);
        }

        fn prehash(arg: Arg) struct { len: usize, hash: u32 } {
            var len: usize = 0;
            var hsh = hash.hash_t([]const u8)(&.{});

            for (arg) |el| {
                len += el.len;
                hsh = hash.hash_append(hsh, el);
            }
            return .{ .len = len, .hash = hsh };
        }

        pub fn init(arg: Arg, allocator: std.mem.Allocator) Error!*Self {
            const pre = Self.prehash(arg);

            return new(arg, pre.len, pre.hash, allocator);
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            const p: [*]align(@alignOf(Self)) const u8 = @ptrCast(self);
            allocator.free(p[0 .. @sizeOf(Self) + self.len]);
        }
    };
}
