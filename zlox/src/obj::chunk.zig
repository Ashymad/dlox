const std = @import("std");

const utils = @import("lib::utils.zig");
const array = @import("lib::array.zig");

const Value = @import("value.zig").Value;
const Obj = @import("obj.zig").Obj;
const OP = @import("op.zig").OP;
const Packed = @import("lib::packed.zig").Packed;

pub fn Chunk(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = void;
        pub const Error = error{OutOfMemory};

        pub const Code = array.Array(u8);
        pub const Constants = array.Array(Value);
        pub const Lines = array.Array(i32);

        obj: Super,
        code: Packed(*Code),
        constants: Packed(*Constants),
        lines: Packed(*Lines),

        pub fn init(_: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .code = try Packed(*Code).create(allocator),
                .constants = try Packed(*Constants).create(allocator),
                .lines = try Packed(*Lines).create(allocator),
            };
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.print("<chunk at {d}>", .{self.lines.ptr().get(0) orelse 0});
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            self.constants.destroy(allocator);
            self.lines.destroy(allocator);
            self.code.destroy(allocator);
            allocator.destroy(self);
        }

        pub fn write(self: *@This(), byte: u8, line: i32) Error!void {
            try self.code.ptr().add(byte);
            try self.lines.ptr().add(line);
        }

        pub fn writeOP(self: *@This(), op: OP, line: i32) Error!void {
            try self.write(@intFromEnum(op), line);
        }

        pub fn addConstant(self: *@This(), val: Value) Error!u8 {
            for (self.constants.ptr().slice(), 0..) |el, i| {
                if (el.eql(val)) {
                    return @intCast(i);
                }
            }
            try self.constants.ptr().add(val);
            return @intCast(self.constants.ptr().len - 1);
        }
    };
}
