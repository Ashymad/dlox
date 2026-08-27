const std = @import("std");

const utils = @import("lib::utils.zig");
const chunk = @import("chunk.zig");

const Packed = @import("lib::packed.zig").Packed;
const Obj = @import("obj.zig").Obj;

pub fn Function(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = Type;
        pub const Error = error{OutOfMemory};

        pub const Type = enum(u8) { Function, Script };

        obj: Super,
        arity: u8,
        chunk: Packed(*chunk.Chunk),
        type: Type,
        upvalue_count: u8,

        pub fn init(tpe: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .chunk = try Packed(*chunk.Chunk).create(allocator),
                .arity = 0,
                .type = tpe,
                .upvalue_count = 0,
            };
            self.chunk.set(try chunk.Chunk.init(allocator));
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            switch (self.type) {
                .Function => _ = try writer.write("<F: "),
                .Script => _ = try writer.write("<S: "),
            }
            _ = try writer.writeAll(">");
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            self.chunk.ptr().deinit();
            self.chunk.destroy(allocator);
            allocator.destroy(self);
        }
    };
}
