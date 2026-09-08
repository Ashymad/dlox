const std = @import("std");

const utils = @import("lib::utils.zig");
const table = @import("lib::table.zig");
const hash = @import("hash.zig");

const Packed = @import("lib::packed.zig").Packed;
const Obj = @import("obj.zig").Obj;
const Value = @import("value.zig").Value;

pub fn Class(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = void;
        pub const Error = error{OutOfMemory};

        pub const Methods = table.Table(*Super.String, *Super.Function, hash.hash_t(*Super.String), Super.String.eql);

        obj: Super,
        methods: Packed(*Methods),

        pub fn init(_: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .methods = try Packed(*Methods).create(allocator),
            };
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(_: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.write("<Class>");
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            self.methods.destroy(allocator);
            allocator.destroy(self);
        }
    };
}
