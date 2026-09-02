const std = @import("std");

const utils = @import("lib::utils.zig");

const Packed = @import("lib::packed.zig").Packed;
const Obj = @import("obj.zig").Obj;

pub fn Closure(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = *Super.Function;
        pub const Error = error{OutOfMemory};

        obj: Super,
        function: Packed(*Super.Function),
        upvalues: Packed([]?*Super.Upvalue),

        pub fn init(arg: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .upvalues = try Packed([]?*Super.Upvalue).alloc2(allocator, arg.upvalue_count, null),
                .function = Packed(*Super.Function).init(arg),
            };
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(_: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.write("<Closure>");
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            self.upvalues.destroy(allocator);
            allocator.destroy(self);
        }
    };
}
