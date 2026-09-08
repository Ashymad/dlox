const std = @import("std");

const utils = @import("lib::utils.zig");

const Packed = @import("lib::packed.zig").Packed;
const GC = @import("gc.zig").GC;
const Value = @import("value.zig").Value;
const Obj = @import("obj.zig").Obj;

pub fn Native(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();
        pub const Error = error{ OutOfMemory, Native };

        pub const Fn = *const fn (*GC, []const Value) Error!Value;

        pub const ArityMin = 0;
        pub const ArityMax = std.math.maxInt(u8);

        pub const Arg = struct {
            fun: Fn,
            arity_min: u8 = ArityMin,
            arity_max: u8 = ArityMax,
        };

        obj: Super,
        fun: Packed(Fn),
        arity_min: u8,
        arity_max: u8,

        pub fn init(arg: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .fun = Packed(Fn).init(arg.fun),
                .arity_min = arg.arity_min,
                .arity_max = arg.arity_max,
            };
            return self;
        }

        pub fn call(self: *const Self, gc: *GC, argCount: u8, args: [*]Value) Error!Value {
            const callable = self.fun.ptr();
            return callable(gc, args[0..argCount]);
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(_: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.write("<Builtin>");
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }
    };
}
