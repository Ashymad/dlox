const std = @import("std");

const utils = @import("lib::utils.zig");

const Packed = @import("lib::packed.zig").Packed;
const Obj = @import("obj.zig").Obj;

pub fn Function(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, InvalidArguments };

        pub const Type = enum(u8) { Function, Script, Closure, Method };

        pub const Chunk = *Super.Chunk;
        pub const Upvalue = ?*Super.Upvalue;

        pub const Arg = struct {
            type: Type = .Function,
            upvalues: u8 = 0,
            chunk: Chunk,
            arity: u8 = 0,
        };

        obj: Super,
        arity: u8,
        chunk: Packed(*Super.Chunk),
        type: Type,
        upvalues: Packed(?[]Upvalue),

        pub fn init(arg: Arg, allocator: std.mem.Allocator) Error!*Self {
            if (if (arg.type == .Closure) arg.upvalues == 0 else arg.upvalues > 0)
                return Error.InvalidArguments;

            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .chunk = Packed(Chunk).init(arg.chunk),
                .arity = arg.arity,
                .type = arg.type,
                .upvalues = try Packed(?[]Upvalue).alloc2(allocator, arg.upvalues, null),
            };
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            switch (self.type) {
                .Function => _ = try writer.write("<Function>"),
                .Script => _ = try writer.write("<Script>"),
                .Closure => _ = try writer.write("<Closure>"),
                .Method => _ = try writer.write("<Method>"),
            }
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
